import XCTest
@testable import OpenGlasses

/// Plan MK P2 — what the Stock screen says about the place: a title per kind that the list's name
/// beats, and the three strings that need the kind.
final class StockPlaceScreenTextTests: XCTestCase {

    func testEachKindHasItsOwnTitle() {
        let expected: [StockPlace.Kind: String] = [
            .van: "Van stock", .truck: "Truck stock", .store: "Store stock", .warehouse: "Warehouse stock", .stock: "Stock",
        ]
        for (kind, title) in expected {
            XCTAssertEqual(StockPlaceScreenText.title(kind), title)
            XCTAssertEqual(StockPlaceScreenText.title(kind, name: nil), title)
            XCTAssertEqual(StockPlaceScreenText.title(kind, name: "   "), title, "a blank name is no name")
        }
    }

    func testTheListsNameWinsOverThePlace() {
        for kind in StockPlace.Kind.allCases {
            XCTAssertEqual(StockPlaceScreenText.title(kind, name: "Main street store"), "Main street store")
            XCTAssertEqual(StockPlaceScreenText.title(kind, name: " Truck 4 "), "Truck 4")
        }
    }

    func testTheTakeoverNamesAVehicleAndOtherwiseTheList() {
        XCTAssertEqual(StockPlaceScreenText.takeOver(.van), "Take over this van")
        XCTAssertEqual(StockPlaceScreenText.takeOver(.truck), "Take over this truck")
        for kind in [StockPlace.Kind.store, .warehouse, .stock] {
            XCTAssertEqual(StockPlaceScreenText.takeOver(kind), "Take over this list", "\(kind)")
        }
    }

    func testTheEmptyListsHintFollowsTheFamily() {
        for kind in [StockPlace.Kind.van, .truck] {
            let hint = StockPlaceScreenText.emptyHint(kind)
            XCTAssertTrue(hint.contains("I've loaded four flame sensors"), hint)
        }
        for kind in [StockPlace.Kind.store, .warehouse, .stock] {
            let hint = StockPlaceScreenText.emptyHint(kind)
            XCTAssertTrue(hint.contains("I've put in six cases of soda water"), hint)
            XCTAssertFalse(hint.lowercased().contains("loaded"), hint)
        }
    }

    func testEachKindHasAPlaceholderName() {
        XCTAssertEqual(StockPlace.Kind.allCases.map(StockPlaceScreenText.namePlaceholder),
                       ["Van 2", "Truck 4", "Main street store", "Warehouse A", "Workshop"])
    }

    func testThePickerAndTheProfileNameEveryKindApart() {
        let names = StockPlace.Kind.allCases.map(StockPlaceScreenText.kindName)
        XCTAssertEqual(Set(names).count, names.count)
        let summaries = StockPlace.Kind.allCases.map(StockPlaceScreenText.profileSummary)
        XCTAssertEqual(Set(summaries).count, summaries.count)
        XCTAssertEqual(StockPlaceScreenText.profileSummary(.store), "Stock is kept in the store")
        XCTAssertEqual(StockPlaceScreenText.profileSummary(.van), "Stock is kept on the van")
    }

    /// No screen string about the place carries a word of the other family's.
    func testPremisesStringsNeverSayVanTruckOrBase() {
        for kind in [StockPlace.Kind.store, .warehouse, .stock] {
            let strings = [StockPlaceScreenText.title(kind), StockPlaceScreenText.takeOver(kind),
                           StockPlaceScreenText.emptyHint(kind), StockPlaceScreenText.namePlaceholder(kind)]
            for string in strings {
                for word in ["van", "truck", "base"] {
                    XCTAssertFalse(string.lowercased().split(whereSeparator: { !$0.isLetter }).contains { $0 == word },
                                   "\(kind): \(string)")
                }
            }
        }
    }

    // MARK: The book numbers are checked against

    func testTheSavedBookIsNoneInstalledOrGone() {
        let installed: Set<String> = ["refrigeration", "supplier"]
        XCTAssertEqual(StockPlaceScreenText.book(saved: nil, installed: installed), .none)
        XCTAssertEqual(StockPlaceScreenText.book(saved: "", installed: installed), .none)
        XCTAssertEqual(StockPlaceScreenText.book(saved: "supplier", installed: installed), .installed("supplier"))
        XCTAssertEqual(StockPlaceScreenText.book(saved: "removed", installed: installed), .gone("removed"))
        XCTAssertEqual(StockPlaceScreenText.book(saved: "supplier", installed: []), .gone("supplier"))
    }
}
