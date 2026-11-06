import XCTest
@testable import Eira

/// 角色包（网页版 charpack.js，4.116）。Fixtures/charpack.zip 由 scripts/make-charpack-fixture.mjs 用网页版自己的 charpack.build 打出来：
/// 原生版装得回网页版的包；原生版打的包再装一次一份不差，并抄给 scripts/check-export.mjs 用网页版的 zip.js、typed.js 读一遍。
final class CharPackTests: StoreTestCase {
    private func me() throws -> Persona {
        let p = try People.createPersona(name: "本机的我")
        try People.setActivePersona(p.id)
        return p
    }

    private func row(_ c: String, _ id: String) throws -> Row? { try Database.shared.get(c, id: id) }

    func testReadDoesNotTouchStore() throws {
        let pack = try CharPack.read(fixture("charpack.zip"))
        XCTAssertEqual(pack.name, "林")
        XCTAssertFalse(pack.exists)
        XCTAssertTrue(pack.history)
        XCTAssertEqual(pack.n("alts"), 1)
        XCTAssertEqual(pack.n("chats"), 1)
        XCTAssertEqual(pack.n("messages"), 3)
        XCTAssertEqual(pack.n("memories"), 1)
        XCTAssertEqual(pack.extras, 3)   // 动态、好友与拉黑、印象
        XCTAssertNil(try row(Collections.characters, "char_pk"))
    }

    func testNotAPack() throws {
        XCTAssertThrowsError(try CharPack.read(fixture("full.zip"))) { e in
            XCTAssertTrue(e.localizedDescription.contains("character.json"), e.localizedDescription)
        }
        XCTAssertThrowsError(try CharPack.read(fixture("data.json")))
    }

    func testInstallWebPack() throws {
        let me = try me()
        let got = try CharPack.install(try CharPack.read(fixture("charpack.zip")))
        XCTAssertEqual(got.charId, "char_pk")
        XCTAssertFalse(got.copied)
        XCTAssertEqual(got.media, 4)

        let c = try XCTUnwrap(try Repo.character("char_pk"))
        XCTAssertEqual(c.persona, "PACK_PERSONA")
        XCTAssertEqual(c.row["webOnlyField"]?["keep"]?.number, 1)
        // 关联的世界书只留本机有的；全局那本与找不到的那本去掉
        XCTAssertEqual(c.lorebookIds, ["lb_own"])
        XCTAssertNotNil(try row(Collections.lorebooks, "lb_own"))
        XCTAssertNil(try row(Collections.lorebooks, "lb_global"))
        // 小号跟着走；指向包外 NPC 的关系留着，读的时候滤掉
        XCTAssertEqual(try Repo.character("char_alt")?.parentId, "char_pk")
        XCTAssertEqual(c.row["relations"]?.array?.count, 2)
        XCTAssertEqual(Relations.of("char_pk").map(\.charId), ["char_alt"])

        // 会话与记忆挂到当前账号下；群不带
        let chat = try XCTUnwrap(try Repo.chat("chat_pk"))
        XCTAssertEqual(chat.personaId, me.id)
        XCTAssertNil(try Repo.chat("chat_grp"))
        XCTAssertEqual(try Repo.messages(chatId: "chat_pk").map(\.id), ["msg_pk1", "msg_pk2", "msg_pk3"])
        let mems = try Repo.memories(charId: "char_pk")
        XCTAssertEqual(mems.map(\.content), ["PACK_MEMORY"])
        XCTAssertEqual(mems.first?.personaId, me.id)
        XCTAssertEqual(mems.first?.vector, [0.5, -0.25, 1])

        // 印象（整理结果不带）、好友与拉黑（hist 清空）、动态
        let imps = try Database.shared.all("impressions", where: "char_pk")
        XCTAssertEqual(imps.map(\.id), ["imp_pk"])
        XCTAssertEqual(imps.first?.string("personaId"), me.id)
        XCTAssertEqual(Impress.evidence(imps.first?["evidence"]).first?["msgId"]?.string, "msg_pk1")
        let tie = try XCTUnwrap(try row("ties", "ti_pk"))
        XCTAssertEqual(tie.string("personaId"), me.id)
        XCTAssertEqual(tie["hist"]?.array?.count, 0)
        XCTAssertTrue(tie.bool("blocked"))
        XCTAssertEqual(try row("moments", "mo_pk")?.strings("likes"), ["me", "char_npc"])

        // 图与语音放回去了，id 不变
        for id in ["img_av", "img_msg", "img_mo"] { XCTAssertNotNil(MediaStore.url(.images, id: id), id) }
        XCTAssertNotNil(MediaStore.url(.files, id: "f_voice"))
        let png = try Data(contentsOf: XCTUnwrap(MediaStore.url(.images, id: "img_msg")))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
    }

    /// 同一个包装两次：整包换一套 id 另建副本，互相指着的都跟着换
    func testInstallTwiceMakesCopy() throws {
        _ = try me()
        try CharPack.install(try CharPack.read(fixture("charpack.zip")))
        let pack = try CharPack.read(fixture("charpack.zip"))
        XCTAssertTrue(pack.exists)
        let got = try CharPack.install(pack)
        XCTAssertTrue(got.copied)
        XCTAssertNotEqual(got.charId, "char_pk")
        XCTAssertEqual(got.media, 0)   // 同一张图不放第二遍

        let copy = try XCTUnwrap(try Repo.character(got.charId))
        XCTAssertEqual(copy.row.string("name"), "林（副本）")
        let alt = try XCTUnwrap(try Repo.characters().first { $0.parentId == got.charId })
        XCTAssertEqual(alt.row.string("name"), "林的小号（副本）")
        XCTAssertTrue((copy.row["relations"]?.array ?? []).contains { $0["charId"]?.string == alt.id })

        let chat = try XCTUnwrap(try Repo.chats().first { $0.characterIds == [got.charId] })
        let msgs = try Repo.messages(chatId: chat.id)
        XCTAssertEqual(msgs.count, 3)
        XCTAssertFalse(msgs.contains { $0.id.hasPrefix("msg_pk") })
        XCTAssertEqual(msgs.first { $0.role == .char }?.authorId, got.charId)
        // 水位线跟着消息换了 id
        XCTAssertEqual(chat.row.string("memoryUpTo"), msgs[1].id)
        // 动态：作者与评论里的小号换成副本，「我」与包外的人不动
        let mo = try XCTUnwrap(try Database.shared.all("moments").first { $0.string("authorId") == got.charId })
        XCTAssertEqual(mo.strings("likes"), ["me", "char_npc"])
        XCTAssertEqual(mo["comments"]?[0]?["authorId"]?.string, alt.id)
        // 印象的依据指着副本里的那条消息
        let imp = try XCTUnwrap(try Database.shared.all("impressions", where: got.charId).first)
        XCTAssertEqual(Impress.evidence(imp["evidence"]).first?["msgId"]?.string, msgs[0].id)
        XCTAssertEqual(Impress.evidence(imp["evidence"]).first?["chatId"]?.string, chat.id)
    }

    /// 原生版打的包：再读回来一份不差；换一份空库装回去。抄一份给 check-export.mjs
    func testBuildRoundTrip() throws {
        _ = try me()
        try CharPack.install(try CharPack.read(fixture("charpack.zip")))
        // 一段群聊与只在群里的记忆不进包
        let grp = Row.new(prefix: "chat", ["group": .bool(true), "characterIds": .array([.string("char_pk"), .string("char_alt")])])
        try Database.shared.put(Collections.chats, grp)
        try Database.shared.put(Collections.memories, Row.new(prefix: "mem", ["charId": .string("char_pk"), "content": .string("G"), "scopeChat": .string(grp.id)]))

        let est = try CharPack.estimate("char_pk")
        XCTAssertEqual(est.chats, 1)
        XCTAssertEqual(est.messages, 3)
        XCTAssertEqual(est.memories, 1)
        XCTAssertEqual(est.images, 3)
        XCTAssertEqual(est.files, 1)

        let built = try CharPack.build("char_pk")
        XCTAssertTrue(built.file.lastPathComponent.hasPrefix("角色-林-"))
        XCTAssertEqual(built.media, 4)
        if let dir = ProcessInfo.processInfo.environment["EXPORT_CHECK_DIR"], !dir.isEmpty {
            let target = URL(fileURLWithPath: dir).appendingPathComponent("charpack.zip")
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: built.file, to: target)
        }
        let pack = try CharPack.read(built.file)
        XCTAssertEqual(pack.data["_format"]?.string, "mini-phone-character")
        XCTAssertEqual(pack.data["_version"]?.number, 2)
        for k in CharPack.kinds { XCTAssertNotNil(pack.data[k]?.array, k) }
        XCTAssertEqual(pack.n("chats"), 1)
        XCTAssertEqual(pack.data["memories"]?[0]?["vec"]?["__f32"]?.string, "AAAAPwAAgL4AAIA/")

        // 换一份空库装回去
        Database.shared.close()
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Database.shared = try Database(url: root.appendingPathComponent("test.sqlite"))
        _ = try me()
        let got = try CharPack.install(try CharPack.read(built.file))
        XCTAssertFalse(got.copied)
        XCTAssertEqual(try Repo.messages(chatId: "chat_pk").count, 3)
        XCTAssertEqual(try Repo.memories(charId: "char_pk").first?.vector, [0.5, -0.25, 1])
        XCTAssertNotNil(MediaStore.url(.images, id: "img_msg"))
        XCTAssertNotNil(MediaStore.url(.files, id: "f_voice"))
        XCTAssertEqual(try Repo.chats().count, 1)
    }

    /// 不带聊天记录：只有角色卡、小号、世界书与衣帽间这一类
    func testWithoutHistory() throws {
        _ = try me()
        try CharPack.install(try CharPack.read(fixture("charpack.zip")))
        let built = try CharPack.build("char_pk", history: false)
        let pack = try CharPack.read(built.file)
        XCTAssertFalse(pack.history)
        XCTAssertEqual(pack.n("chats"), 0)
        XCTAssertEqual(pack.n("messages"), 0)
        XCTAssertEqual(pack.n("memories"), 0)
        XCTAssertEqual(pack.n("moments"), 0)
        XCTAssertEqual(pack.n("alts"), 1)
        XCTAssertEqual(pack.n("lorebooks"), 1)
    }

    func testFileName() {
        let d = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(CharPack.fileName("林/小:林", now: d), "角色-林小林-2025-10-09.zip")
        XCTAssertEqual(CharPack.fileName("", now: d), "角色-未命名-2025-10-09.zip")
    }
}
