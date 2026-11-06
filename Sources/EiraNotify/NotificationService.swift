import Foundation
import UserNotifications

/// 通知扩展（网页版 ARCHITECTURE 4.896 的 NotifyService）：Eira 推送到了手机上，在这里解开盒子，换成「角色名：正文」。
///
/// 推送转发看不到内容：用户自己的后台消息服务器用应用生成的钥匙加密，转发只把密文交给苹果。苹果送来的推送锁屏上
/// 原本只有一句「收到一条新消息」，系统先交给这里，这里用同一把钥匙（App Group 里，应用写进去的）解开、改写，再交回系统显示。
/// 读不到钥匙、解不开、超时，一律原样显示那一句不带内容的话：内容绝不以明文出现在推送里，宁可少显示。
final class NotificationService: UNNotificationServiceExtension {
    private var done: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        done = contentHandler
        fallback = request.content
        let c = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        if let a = PushBox.alert(PushBox.open(request.content.userInfo, key: PushBox.groupKey())) {
            if !a.title.isEmpty { c.title = a.title }
            if !a.body.isEmpty { c.body = a.body }
            if !a.chatId.isEmpty {
                // 点开进那段会话：和应用自己发的本地通知同一个写法（Notifier 读 chatId）；同一段会话的通知叠在一起
                c.userInfo = ["chatId": a.chatId]
                c.threadIdentifier = a.chatId
                if let att = NotifyFaces.attachment(chatId: a.chatId) { c.attachments = [att] }
            }
        }
        contentHandler(c)
        done = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let d = done, let f = fallback { d(f) }
        done = nil
    }
}
