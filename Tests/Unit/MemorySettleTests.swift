import XCTest
@testable import Eira

/// 批量处理进行中的事（网页版 4.534）：了结写上了结时间；改为事件去掉状态与到期日；群聊里同一件事的几份一起改；不是进行中的不动
final class MemorySettleTests: StoreTestCase {
    private func put(_ id: String, kind: String, twin: String = "") throws {
        var f: [String: JSONValue] = ["id": .string(id), "content": .string(id), "kind": .string(kind), "status": .string(kind == "open" ? "open" : ""),
                                      "dueAt": .string(kind == "open" ? "2026-11-01" : ""), "category": .string(kind == "open" ? "pending" : "fact")]
        if !twin.isEmpty { f["twin"] = .string(twin) }
        try Database.shared.put(Collections.memories, Row(fields: f))
    }

    func testSettle() throws {
        try put("m1", kind: "open", twin: "t1")
        try put("m2", kind: "open", twin: "t1")
        try put("m3", kind: "open")
        try put("f1", kind: "fact")
        XCTAssertEqual(try Knowledge.settle(["m1", "f1"], as: "done"), 2)
        let m2 = try XCTUnwrap(Database.shared.get(Collections.memories, id: "m2"))
        XCTAssertEqual(m2.string("status"), "done")
        XCTAssertNotNil(m2.number("doneAt"))
        XCTAssertEqual(try Database.shared.get(Collections.memories, id: "f1")?.string("status"), "")
        XCTAssertEqual(try Knowledge.settle(["m3"], as: "event"), 1)
        let m3 = try XCTUnwrap(Database.shared.get(Collections.memories, id: "m3"))
        XCTAssertEqual(m3.string("kind"), "event")
        XCTAssertEqual(m3.string("dueAt"), "")
        XCTAssertEqual(m3.string("status"), "")
    }
}
