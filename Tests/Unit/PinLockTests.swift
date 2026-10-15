import XCTest
@testable import Eira

/// 锁屏密码：存加盐的哈希不存原文；与网页版同一种写法；连错五次开始要等；清掉之后锁屏一并可关
final class PinLockTests: StoreTestCase {
    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "phone.pin.fail")
        try super.tearDownWithError()
    }

    func testSetCheckAndWait() throws {
        XCTAssertFalse(PinLock.hasPin())
        XCTAssertThrowsError(try PinLock.set("12a4"))
        XCTAssertThrowsError(try PinLock.set("12345"))
        try PinLock.set("2580")
        let p = try XCTUnwrap(PinLock.pin())
        XCTAssertNotEqual(p["hash"]?.string, "2580")
        XCTAssertEqual(p["hash"]?.string, PinLock.digest("2580", salt: p["salt"]?.string ?? ""), "salt:pin 的 SHA-256，与网页版一致")
        XCTAssertEqual(PinLock.length(), 4)
        XCTAssertTrue(PinLock.check("2580"))

        let now = Date()
        for _ in 0..<4 { XCTAssertFalse(PinLock.check("0000", now: now)) }
        XCTAssertEqual(PinLock.waitLeft(now: now), 0, "前四次不用等")
        XCTAssertFalse(PinLock.check("0000", now: now))
        XCTAssertEqual(PinLock.waitLeft(now: now), 30)
        XCTAssertFalse(PinLock.check("2580", now: now), "等待中输对也不放")
        XCTAssertTrue(PinLock.check("2580", now: now.addingTimeInterval(31)))
        XCTAssertEqual(PinLock.failCount(), 0)
    }

    func testClearWithLockOff() throws {
        try PinLock.set("135790")
        XCTAssertEqual(PinLock.length(), 6)
        try PinLock.clear(lockOff: true)
        XCTAssertFalse(PinLock.hasPin())
        XCTAssertEqual(AppSettings.load().raw["showLockScreen"]?.bool, false)
    }

    /// 网页版设的密码原生版认得：同一份 {hash, salt, len}
    func testWebPin() throws {
        let salt = "00112233445566778899aabbccddeeff"
        try setSettings(["lockPin": .object(["hash": .string(PinLock.digest("1234", salt: salt)), "salt": .string(salt), "len": .number(4)])])
        XCTAssertTrue(PinLock.check("1234"))
        XCTAssertEqual(PinLock.digest("1234", salt: "s"), "663e504d0f9c7f45da38f1fc40ca8c18dd1abe4614f49333762cc02ba8b47c97", "与网页版 crypto.subtle 的写法一致：小写十六进制")
    }
}
