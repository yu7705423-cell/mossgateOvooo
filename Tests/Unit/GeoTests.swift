import XCTest
@testable import Eira

/// 共享位置：距离本机算、空值不当 0、没开或少一端时不注入、只有地名时不给数字。
final class GeoTests: StoreTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try importFixture("data.json")
    }

    func testDistance() {
        let bj = Geo.Spot(place: "北京", lat: 39.90, lng: 116.41), sh = Geo.Spot(place: "上海", lat: 31.23, lng: 121.47)
        let km = try? XCTUnwrap(Geo.distance(bj, sh))
        XCTAssertEqual(km ?? 0, 1067, accuracy: 15)
        XCTAssertEqual(Geo.distanceText(0.3), "300 米")
        XCTAssertEqual(Geo.distanceText(3.25), "3.2 公里")
        XCTAssertEqual(Geo.distanceText(1067.4), "1067 公里")
        // 只填了地名的那一端没有坐标，不当成 (0, 0)
        XCTAssertNil(Geo.clean(.object(["place": .string("某处"), "lat": .null, "lng": .null]))?.lat)
        XCTAssertNil(Geo.distance(Geo.Spot(place: "某处"), sh))
    }

    func testBlock() throws {
        try Geo.setSpot("chat_a", side: "me", Geo.Spot(place: "北京", lat: 39.90, lng: 116.41))
        try Geo.setSpot("chat_a", side: "char", Geo.Spot(place: "上海", lat: 31.23, lng: 121.47))
        XCTAssertEqual(Geo.block(try XCTUnwrap(Repo.chat("chat_a"))), "")   // 没开
        try Geo.setOn("chat_a", true)
        let b = Geo.block(try XCTUnwrap(Repo.chat("chat_a")))
        XCTAssertTrue(b.contains("[你们隔多远]"))
        XCTAssertTrue(b.contains("公里"))
        let chat = try XCTUnwrap(Repo.chat("chat_a"))
        let built = try ChatPrompt.build(chat: chat, char: XCTUnwrap(Repo.character("char_a")), settings: .load())
        XCTAssertTrue(built.system.contains("[你们隔多远]"))
        try Geo.setSpot("chat_a", side: "char", Geo.Spot(place: "海边"))
        XCTAssertTrue(Geo.block(try XCTUnwrap(Repo.chat("chat_a"))).contains("no distance"))
    }
}
