import XCTest
@testable import Eira

/// 读网页版导出的备份。测试文件都是网页版自己的代码打的（scripts/make-fixtures.mjs）。
final class ImportTests: StoreTestCase {
    func testFullZip() throws {
        // 本机已经有一套接口：备份里没带接口，导入后要留着
        try setSettings(["services": .object(["chat": .object(["presets": .array([.object(["id": .string("svc_local")])])])])])

        let r = try importFixture("full.zip")
        XCTAssertEqual(r.rows, 11)
        XCTAssertEqual(r.collections, 8)
        XCTAssertEqual(r.dataVersion, 12)
        XCTAssertTrue(r.keptLocalServices)
        // 压缩图、原图、文件各一份；原图挂的那一张不在的不放；内容是 ZIP 的坏图报出来
        XCTAssertEqual(r.media, 3)
        XCTAssertEqual(r.bad, ["images/img_bad.png"])
        XCTAssertNil(MediaStore.url(.images, id: "img_bad"))
        XCTAssertNil(MediaStore.url(.imagesOrig, id: "img_ghost"))

        let img = try XCTUnwrap(MediaStore.url(.images, id: "img_a"))
        XCTAssertEqual(try Data(contentsOf: img).prefix(4), Data([0x89, 0x50, 0x4e, 0x47]))
        XCTAssertNotNil(MediaStore.url(.imagesOrig, id: "img_a"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(MediaStore.url(.files, id: "f_a"))), Data("ID3fakeaudio".utf8))

        // 原生版不认识的数据域、不认识的字段都原样留着
        XCTAssertEqual(try Database.shared.get("futureThings", id: "ft_1")?.string("whatever"), "x")
        let char = try XCTUnwrap(Repo.character("char_a"))
        XCTAssertEqual(char.row["webOnlyField"]?["keep"]?.bool, true)

        // 设置：网页版独有的键留着，本机的接口留着
        let s = AppSettings.load()
        XCTAssertEqual(s.raw["someWebOnlyKey"]?["nested"]?.array?.count, 3)
        XCTAssertEqual(s.chatPresets.map(\.id), ["svc_local"])

        // 消息按会话查、按时间排
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").map(\.id), ["msg_1", "msg_2", "msg_3"])
        XCTAssertEqual(try Repo.messages(chatId: "chat_a", limit: 2).map(\.id), ["msg_2", "msg_3"])

        // 记忆的向量：网页版存成 {"__f32": base64}
        let mem = try XCTUnwrap(Repo.memories(charId: "char_a").first { $0.id == "mem_1" })
        XCTAssertEqual(mem.vector, [0.5, -0.25, 1])
    }

    func testJSONOnly() throws {
        let r = try importFixture("data.json")
        XCTAssertEqual(r.rows, 11)
        XCTAssertEqual(r.media, 0)
        XCTAssertEqual(try Repo.chats().count, 1)
    }

    func testBackupWithKeysReplacesServices() throws {
        try setSettings(["services": .object(["chat": .object(["presets": .array([.object(["id": .string("svc_local")])])])])])
        let r = try importFixture("with-keys.json")
        XCTAssertFalse(r.keptLocalServices)
        XCTAssertEqual(AppSettings.load().chatPresets.map(\.id), ["svc_b"])
    }

    func testSealed() throws {
        XCTAssertThrowsError(try importFixture("sealed.bin")) { e in
            guard case .needPass? = e as? Vault.Failure else { return XCTFail("应要求口令，实际：\(e)") }
        }
        XCTAssertThrowsError(try importFixture("sealed.bin", password: "不对的口令")) { e in
            guard case .badPass? = e as? Vault.Failure else { return XCTFail("应报口令不正确，实际：\(e)") }
        }
        let r = try importFixture("sealed.bin", password: "口令123")
        XCTAssertEqual(r.rows, 11)
        XCTAssertEqual(r.media, 3)
    }

    /// 任何一种失败都不许动已有的数据（网页版 restore 的头一条规矩）。
    func testFailuresLeaveExistingDataAlone() throws {
        try importFixture("full.zip")
        let before = try Database.shared.counts()

        XCTAssertThrowsError(try importFixture("sealed-truncated.bin", password: "口令123"))
        XCTAssertThrowsError(try importFixture("old.json")) { e in
            guard case .tooOld(5)? = e as? BackupImporter.Failure else { return XCTFail("应报版本过旧，实际：\(e)") }
        }
        XCTAssertThrowsError(try importFixture("not-backup.json")) { e in
            guard case .notBackup? = e as? BackupImporter.Failure else { return XCTFail("应报不是备份，实际：\(e)") }
        }

        XCTAssertEqual(try Database.shared.counts(), before)
        XCTAssertNotNil(MediaStore.url(.images, id: "img_a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(MediaStore.url(.images, id: "img_a")).path))
    }

    /// 再导一次是整份替换，不是叠加。
    func testReimportReplaces() throws {
        try importFixture("full.zip")
        try Repo.save(Message.new(chatId: "chat_a", role: .user, authorId: "me", content: "导入之后新发的"))
        try importFixture("full.zip")
        XCTAssertEqual(try Repo.messages(chatId: "chat_a").count, 3)
    }
}
