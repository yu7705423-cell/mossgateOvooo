import XCTest
@testable import Eira

/// 「联系」里点了才调的几样（批量生成 NPC、按分区拆分我的人设、整理与对照对我的印象）：
/// 接口一直失败时，默认设置下点一次只打一次，不换接口；都不是自动触发的，不进 ExtraCalls。
extension CostTests {
    func testContactTasksFailingIsOneRequestPerTap() async throws {
        let me = try XCTUnwrap(try Repo.activePersona())
        let runs: [(String, () async throws -> Void)] = [
            ("card.npc", { _ = try await NpcGen.generate(charId: "char_a", count: 3) }),
            ("self.import", { _ = try await SelfProfile.parse("一整段人设") }),
            ("impress.organize", { try await ImpressTask.organize(charId: "char_a", personaId: me.id) }),
        ]
        for (task, run) in runs {
            MockNet.reset { _, _ in .init(status: 500, body: #"{"error":{"message":"boom"}}"#) }
            let before = await Usage.shared.today(task: task)
            do { try await run(); XCTFail("\(task) 应当失败") } catch {}
            XCTAssertEqual(MockNet.count, 1, task)
            let after = await Usage.shared.today(task: task)
            XCTAssertEqual(after - before, 1, task)
            XCTAssertFalse(ExtraCalls.all.contains { $0.id == task }, task)
        }
        XCTAssertNil(Impress.draft("char_a", me.id))
    }
}
