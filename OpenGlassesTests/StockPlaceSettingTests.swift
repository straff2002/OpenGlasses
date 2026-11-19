import XCTest
@testable import OpenGlasses

/// Plan MK P0 — who sets the place (§2): the organisation's profile, then the list, then van.
final class StockPlaceSettingTests: XCTestCase {

    func testWithNothingSetItIsAVan() {
        XCTAssertEqual(StockPlaceSetting.resolve(profile: nil, list: nil),
                       .init(kind: .van, isLocked: false))
    }

    func testTheListsOwnChoiceWinsOverTheDefault() {
        XCTAssertEqual(StockPlaceSetting.resolve(profile: nil, list: .store),
                       .init(kind: .store, isLocked: false))
    }

    func testTheProfileWinsOverTheListAndLocksIt() {
        XCTAssertEqual(StockPlaceSetting.resolve(profile: "warehouse", list: .store),
                       .init(kind: .warehouse, isLocked: true))
        XCTAssertEqual(StockPlaceSetting.resolve(profile: "truck", list: nil),
                       .init(kind: .truck, isLocked: true))
    }

    func testAProfileThatSaysVanStillLocksIt() {
        XCTAssertEqual(StockPlaceSetting.resolve(profile: "van", list: .stock),
                       .init(kind: .van, isLocked: true))
    }

    func testAnUnknownProfileKindIsIgnoredNeverGuessed() {
        XCTAssertEqual(StockPlaceSetting.resolve(profile: "cellar", list: .store),
                       .init(kind: .store, isLocked: false))
        XCTAssertEqual(StockPlaceSetting.resolve(profile: "", list: nil),
                       .init(kind: .van, isLocked: false))
    }

    func testRemovingTheProfileRestoresTheListsChoice() {
        let list: StockPlace.Kind = .stock
        XCTAssertEqual(StockPlaceSetting.resolve(profile: "store", list: list).kind, .store)
        XCTAssertEqual(StockPlaceSetting.resolve(profile: nil, list: list).kind, .stock,
                       "the profile's place was never written into the list")
    }
}
