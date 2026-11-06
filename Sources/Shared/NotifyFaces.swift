import Foundation
import UserNotifications

/// 通知上的头像（网页版 ARCHITECTURE 4.711）：单聊是这段会话里该显示的那张（专用头像优先），群聊是群头像，没有就第一个成员的。
///
/// 应用自己弹的通知直接读库；通知扩展读不到库，应用在退到后台时把交给后台消息服务器的那几段会话的头像缩成小图，
/// 写进 App Group 的 Faces/<会话>.jpg，扩展按会话取。
enum NotifyFaces {
    static var dir: URL? { AppGroup.container?.appendingPathComponent("Faces", isDirectory: true) }

    static func file(_ chatId: String, in dir: URL? = NotifyFaces.dir) -> URL? {
        guard WidgetStore.okName(chatId), let dir else { return nil }
        return dir.appendingPathComponent(chatId + ".jpg")
    }

    /// 系统要的附件：先抄一份到临时目录，系统会把附件文件挪走
    static func attachment(chatId: String, from dir: URL? = NotifyFaces.dir) -> UNNotificationAttachment? {
        guard let src = file(chatId, in: dir), FileManager.default.fileExists(atPath: src.path) else { return nil }
        return attachment(copying: src)
    }

    static func attachment(copying src: URL) -> UNNotificationAttachment? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: src, to: tmp)
            return try UNNotificationAttachment(identifier: "face", url: tmp, options: nil)
        } catch {
            return nil
        }
    }
}
