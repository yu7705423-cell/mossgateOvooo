import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 存图与读图。
///
/// 存：最长边压到 `photoMax`（网页版 db/images.js 的 PHOTO_MAX），按原来的方向摆正；有透明的存 PNG，其余 JPEG；
/// 动图原样存，不压（压了就不动了）。
/// 读：按要显示的大小缩小着解码，解出来的放进内存缓存。长列表里每个气泡都整张解码，几十张就把内存吃满。
enum Images {
    static let photoMax: CGFloat = 1280
    /// 头像（网页版 ICON_MAX）
    static let iconMax: CGFloat = 256

    /// 存一张图，返回新的图片 id（和网页版同样的 img 前缀）。maxPixel 是最长边。
    static func save(_ data: Data, maxPixel: CGFloat = photoMax) throws -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            throw StoreError(message: "无法读取这张图片")
        }
        let id = Ids.make("img")
        let out: Data
        let ext: String
        if CGImageSourceGetCount(src) > 1, (CGImageSourceGetType(src) as String?) == UTType.gif.identifier {
            out = data
            ext = "gif"
        } else {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw StoreError(message: "无法读取这张图片")
            }
            let image = UIImage(cgImage: cg)
            if hasAlpha(cg), let png = image.pngData() {
                out = png; ext = "png"
            } else if let jpg = image.jpegData(compressionQuality: 0.85) {
                out = jpg; ext = "jpg"
            } else {
                throw StoreError(message: "无法压缩这张图片")
            }
        }
        let dir = AppPaths.media.appendingPathComponent(MediaKind.images.rawValue, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try out.write(to: dir.appendingPathComponent("\(id).\(ext)"), options: .atomic)
        } catch {
            throw StoreError(message: "图片写入失败：\(error.localizedDescription)")
        }
        try Database.shared.registerMedia(kind: MediaKind.images.rawValue, id: id, ext: ext, bytes: out.count)
        return id
    }

    private static func hasAlpha(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: return true
        default: return false
        }
    }

    static func mediaType(ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }

    // MARK: - 读

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 80 * 1024 * 1024
        return c
    }()

    /// 按 maxPixel 缩小着解码。读不到返回 nil。
    static func load(_ id: String, maxPixel: CGFloat) async -> UIImage? {
        guard !id.isEmpty else { return nil }
        let key = "\(id)@\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = MediaStore.url(.images, id: id) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let image {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }
}
