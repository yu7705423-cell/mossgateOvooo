import XCTest
@testable import Eira

/// 导出成网页版的备份格式，再读回来一份不差。
///
/// 环境变量 EXPORT_CHECK_DIR 有值时（CI 里设），把几份导出的文件抄到那里，
/// 由 scripts/check-export.mjs 用网页版自己的 zip.js、vault.js、typed.js 再读一遍。
final class ExportTests: StoreTestCase {
    private func keep(_ url: URL, as name: String) {
        guard let dir = ProcessInfo.processInfo.environment["EXPORT_CHECK_DIR"], !dir.isEmpty else { return }
        let target = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: url, to: target)
    }

    /// 换一份空库，把导出的文件导回来。
    private func reimport(_ url: URL, password: String = "") throws -> BackupImporter.Report {
        Database.shared.close()
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Database.shared = try Database(url: root.appendingPathComponent("test.sqlite"))
        return try BackupImporter.run(file: url, password: password) { _ in }
    }

    func testZipRoundTrip() throws {
        try importFixture("full.zip")
        // 原生版自己加的东西也要带出去
        _ = try ChatEngine.send(text: "NATIVE_MESSAGE", chatId: "chat_a")
        let before = try Database.shared.counts()

        let r = try BackupExporter.run(.init(media: true))
        XCTAssertEqual(r.file.pathExtension, "zip")
        XCTAssertEqual(r.media, 3)
        keep(r.file, as: "full.zip")

        let back = try reimport(r.file)
        XCTAssertEqual(back.media, 3)
        XCTAssertTrue(back.bad.isEmpty)
        XCTAssertEqual(try Database.shared.counts(), before)
        XCTAssertTrue(try Repo.messages(chatId: "chat_a").contains { $0.content == "NATIVE_MESSAGE" })
        // 不认识的数据域与字段原样带回
        XCTAssertNotNil(try Database.shared.get("futureThings", id: "ft_1"))
        XCTAssertEqual(try Repo.character("char_a")?.row["webOnlyField"]?["keep"]?.bool, true)
        XCTAssertEqual(try Repo.memories(charId: "char_a").first { $0.id == "mem_1" }?.vector, [0.5, -0.25, 1])
        let img = try XCTUnwrap(MediaStore.url(.images, id: "img_a"))
        XCTAssertEqual(try Data(contentsOf: img).prefix(4), Data([0x89, 0x50, 0x4e, 0x47]))
    }

    func testJSONOnly() throws {
        try importFixture("full.zip")
        let r = try BackupExporter.run(.init(media: false))
        XCTAssertEqual(r.file.pathExtension, "json")
        XCTAssertEqual(r.media, 0)
        keep(r.file, as: "data.json")
        let back = try reimport(r.file)
        XCTAssertEqual(back.rows, 11)
    }

    func testSealedRoundTrip() throws {
        try importFixture("full.zip")
        let r = try BackupExporter.run(.init(media: true, password: "导出口令"))
        keep(r.file, as: "sealed.bin")
        XCTAssertThrowsError(try reimport(r.file, password: "错的"))
        let back = try reimport(r.file, password: "导出口令")
        XCTAssertEqual(back.rows, 11)
        XCTAssertEqual(back.media, 3)
    }

    /// 默认不带接口与密钥；打开才带。GitHub 备份的口令无论如何不进文件。
    func testKeysExcludedByDefault() throws {
        try importFixture("data.json")
        try setSettings([
            "services": .object(["chat": .object(["presets": .array([.object(["id": .string("svc"), "apiKey": .string("SECRET_KEY")])])])]),
            "apiKey": .string("OLD_SECRET"),
            "githubBackup": .object(["token": .string("GH_TOKEN"), "password": .string("GH_PASS"), "repo": .string("r")]),
        ])
        let plain = try String(contentsOf: BackupExporter.run(.init(media: false)).file, encoding: .utf8)
        for secret in ["SECRET_KEY", "OLD_SECRET", "GH_TOKEN", "GH_PASS"] { XCTAssertFalse(plain.contains(secret), secret) }
        XCTAssertTrue(plain.contains("\"repo\""))

        let withKeys = try String(contentsOf: BackupExporter.run(.init(media: false, keys: true)).file, encoding: .utf8)
        XCTAssertTrue(withKeys.contains("SECRET_KEY"))
        XCTAssertTrue(withKeys.contains("GH_TOKEN"))
        XCTAssertFalse(withKeys.contains("GH_PASS"))
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.of(Data("123456789".utf8)), 0xCBF4_3926)
    }
}
