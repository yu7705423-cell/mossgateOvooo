import Foundation

/// 图片与文件。内容按原来的 id 存成独立的文件，登记在数据库的 `media` 表里。
///
/// 目录：`media/images/<id>.<ext>`、`media/images-orig/<id>.<ext>`、`media/files/<id>.<ext>`，
/// 和网页版备份 ZIP 里的目录一一对应。消息、角色卡里存的是 id，id 不能变。
enum MediaKind: String, CaseIterable, Sendable {
    case images
    case imagesOrig = "images-orig"
    case files
}

enum MediaStore {
    static func url(_ kind: MediaKind, id: String) -> URL? {
        guard !id.isEmpty, let ext = try? Database.shared.mediaExt(kind: kind.rawValue, id: id) else { return nil }
        return AppPaths.media.appendingPathComponent(kind.rawValue).appendingPathComponent("\(id).\(ext)")
    }

    /// 导入时先把全部媒体写进一个暂存目录，数据库那边提交成功之后再整个换上去。
    /// 中途失败，正在用的那一份一个文件都不动。
    final class Staging {
        let dir: URL
        private(set) var written: [(kind: MediaKind, id: String, ext: String, bytes: Int)] = []

        init() throws {
            dir = AppPaths.root.appendingPathComponent("media-staging-\(UUID().uuidString)", isDirectory: true)
            for k in MediaKind.allCases {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent(k.rawValue), withIntermediateDirectories: true)
            }
        }

        func write(_ kind: MediaKind, id: String, ext: String, data: Data) throws {
            let url = dir.appendingPathComponent(kind.rawValue).appendingPathComponent("\(id).\(ext)")
            do { try data.write(to: url, options: .atomic) }
            catch { throw StoreError(message: "写入图片或文件失败（\(id)）：\(error.localizedDescription)") }
            written.append((kind, id, ext, data.count))
        }

        /// 换上去：旧目录挪开，新目录挪进来，再删旧的。
        func commit() throws {
            let fm = FileManager.default
            let live = AppPaths.media
            let old = AppPaths.root.appendingPathComponent("media-old-\(UUID().uuidString)", isDirectory: true)
            if fm.fileExists(atPath: live.path) { try fm.moveItem(at: live, to: old) }
            do { try fm.moveItem(at: dir, to: live) }
            catch {
                // 新的放不进去，把旧的挪回来，至少不比导入之前更坏
                if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: live) }
                throw StoreError(message: "图片与文件换入失败：\(error.localizedDescription)")
            }
            try? fm.removeItem(at: old)
        }

        func discard() { try? FileManager.default.removeItem(at: dir) }
    }
}
