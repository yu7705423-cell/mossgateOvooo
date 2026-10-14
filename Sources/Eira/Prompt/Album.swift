import Foundation
import Photos

/// 相册（网页版 system/album.js）。数据域 albums、photos，与网页版同一格式：
///     albums  { name, cover（photo id，可空）}
///     photos  { albumId（空为未归类）, kind: image | card, imageId, from: { chatId, charId, name, at }, note,
///               card 另有 title, msgs（冻起来的消息副本）, shotId }
/// 相册里存的是同一个图片 id，不另压一份：从相册里移除不动会话里那一条。原生版不删图片文件（删图要先核引用，网页版第 20 条）。
/// 消息卡片（几条消息连同当时的美化存成一张）原生版只显示存下的消息，不渲染当时的美化 CSS。
enum Album {
    static let albums = "albums"
    static let photos = "photos"

    struct Photo: Identifiable, Equatable {
        var row: Row
        var id: String { row.id }
        var albumId: String { row.string("albumId") }
        var kind: String { row.string("kind").isEmpty ? "image" : row.string("kind") }
        var imageId: String { row.string("imageId") }
        var fromName: String { row["from"]?.object?["name"]?.string ?? "" }
        var fromAt: Double { row["from"]?.object?["at"]?.number ?? (row.number("createdAt") ?? 0) }
        var hasFrom: Bool { row["from"]?.object != nil }
        var title: String { row.string("title") }
        /// 卡片里存下的那几条：名字与正文
        var cardLines: [(name: String, text: String, mine: Bool)] {
            (row["msgs"]?.array ?? []).compactMap { v in
                guard let o = v.object else { return nil }
                return (o["_name"]?.string ?? "", o["content"]?.string ?? "", o["role"]?.string == "user")
            }
        }
    }

    static func listAlbums() -> [Row] {
        ((try? Database.shared.all(albums)) ?? []).sorted { ($0.number("createdAt") ?? 0) < ($1.number("createdAt") ?? 0) }
    }

    static func album(_ id: String) -> Row? { try? Database.shared.get(albums, id: id) }

    static func listPhotos(_ albumId: String) -> [Photo] {
        all().filter { $0.albumId == albumId }
    }

    static func all() -> [Photo] {
        ((try? Database.shared.all(photos)) ?? []).map(Photo.init).sorted { ($0.row.number("createdAt") ?? 0) > ($1.row.number("createdAt") ?? 0) }
    }

    static func photo(_ id: String) -> Photo? { (try? Database.shared.get(photos, id: id)).map(Photo.init) }

    @discardableResult
    static func createAlbum(_ name: String) throws -> Row {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw StoreError(message: "请填写名称") }
        let r = Row.new(prefix: "al", ["name": .string(String(n.prefix(40))), "cover": .null])
        try Database.shared.put(albums, r)
        return r
    }

    static func renameAlbum(_ id: String, _ name: String) throws {
        guard var r = album(id) else { return }
        r["name"] = .string(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)))
        r.touch()
        try Database.shared.put(albums, r)
    }

    /// 删相册。里面的照片不跟着删，退回「未归类」
    static func removeAlbum(_ id: String) throws {
        for p in listPhotos(id) { try move(p.id, to: "") }
        try Database.shared.delete(albums, id: id)
    }

    @discardableResult
    static func saveImage(_ imageId: String, albumId: String = "", from: [String: JSONValue]? = nil) throws -> Row {
        guard !imageId.isEmpty else { throw StoreError(message: "没有图片") }
        let r = Row.new(prefix: "ph", ["albumId": .string(albumId), "kind": .string("image"), "imageId": .string(imageId),
                                        "from": from.map { .object($0) } ?? .null, "note": .string("")])
        try Database.shared.put(photos, r)
        return r
    }

    /// 从会话里那一条存进相册：记下是谁发的、哪一段对话、什么时候
    @discardableResult
    static func saveFrom(_ m: Message, name: String) throws -> Row {
        let stickerImage = (try? Database.shared.get(Stickers.collection, id: m.row.string("stickerId")))?.string("imageId") ?? ""
        let imageId = !m.imageId.isEmpty ? m.imageId : stickerImage
        return try saveImage(imageId, from: ["chatId": .string(m.chatId), "charId": .string(m.authorId),
                                             "name": .string(name), "at": .number(m.createdAt)])
    }

    static func move(_ id: String, to albumId: String) throws {
        guard var r = try Database.shared.get(photos, id: id) else { return }
        r["albumId"] = .string(albumId)
        r.touch()
        try Database.shared.put(photos, r)
    }

    static func setCover(_ albumId: String, _ photoId: String) throws {
        guard var r = album(albumId) else { return }
        r["cover"] = .string(photoId)
        r.touch()
        try Database.shared.put(albums, r)
    }

    /// 从相册里移除。图片文件不删：会话里那一条可能还指着它
    static func removePhoto(_ id: String) throws {
        for var a in listAlbums() where a.string("cover") == id {
            a["cover"] = .null
            a.touch()
            try Database.shared.put(albums, a)
        }
        try Database.shared.delete(photos, id: id)
    }

    static func coverImage(_ albumRow: Row) -> String {
        if let p = photo(albumRow.string("cover")), !p.imageId.isEmpty { return p.imageId }
        return listPhotos(albumRow.id).first(where: { !$0.imageId.isEmpty })?.imageId ?? ""
    }

    /// 存到系统「照片」，回给界面上要说的那一句
    static func toDevice(_ imageId: String) async -> String {
        guard let url = MediaStore.url(.images, id: imageId) else { return "这张图片的文件不存在" }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return "没有添加照片的权限。可在「设置 - Eiraowo - 照片」中开启。" }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url) }
            return "已存到手机相册"
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
    }
}
