import XCTest
@testable import OpenGlasses

/// Plan MK P0 — the words the model hears about each place (§3). A van says what it says today;
/// premises never borrow a vehicle's words; the neutral kind names no place at all.
final class StockPlaceWordingTests: XCTestCase {

    func testAVanSaysWhatItSaysToday() {
        let van = StockPlaceWording(.van)
        XCTAssertEqual(van.location, "on the van")
        XCTAssertEqual(van.list, "the van list")
        XCTAssertEqual(van.putVerb, "loaded")
        XCTAssertEqual(van.putThere, "put on the van")
        XCTAssertEqual(van.takenVerb, "used")
        XCTAssertEqual(van.takenFrom, "taken off the van")
        XCTAssertEqual(van.usualFigure, "standard load")
        XCTAssertEqual(van.setByOffice, "base")
        XCTAssertEqual(van.setByList, "this truck", "the workbook already says This truck for a van")
        XCTAssertEqual(van.handover, "send the stock to base")
        XCTAssertEqual(van.title, "Van stock")
    }

    func testATruckUsesItsOwnNoun() {
        let truck = StockPlaceWording(.truck)
        XCTAssertEqual(truck.location, "on the truck")
        XCTAssertEqual(truck.list, "the truck list")
        XCTAssertEqual(truck.putVerb, "loaded")
        XCTAssertEqual(truck.putThere, "put on the truck")
        XCTAssertEqual(truck.takenVerb, "used")
        XCTAssertEqual(truck.takenFrom, "taken off the truck")
        XCTAssertEqual(truck.usualFigure, "standard load")
        XCTAssertEqual(truck.setByOffice, "base")
        XCTAssertEqual(truck.setByList, "this truck")
        XCTAssertEqual(truck.handover, "send the stock to base")
        XCTAssertEqual(truck.title, "Truck stock")
    }

    func testAStoreSpeaksAsAShop() {
        let store = StockPlaceWording(.store)
        XCTAssertEqual(store.location, "in the store")
        XCTAssertEqual(store.list, "the stock list")
        XCTAssertEqual(store.putVerb, "received")
        XCTAssertEqual(store.putThere, "put in the store")
        XCTAssertEqual(store.takenVerb, "sold or used")
        XCTAssertEqual(store.takenFrom, "taken from the store")
        XCTAssertEqual(store.usualFigure, "par level")
        XCTAssertEqual(store.setByOffice, "the office")
        XCTAssertEqual(store.setByList, "this store")
        XCTAssertEqual(store.handover, "send the stock list")
        XCTAssertEqual(store.title, "Store stock")
    }

    func testAWarehouseSpeaksAsPremises() {
        let warehouse = StockPlaceWording(.warehouse)
        XCTAssertEqual(warehouse.location, "in the warehouse")
        XCTAssertEqual(warehouse.list, "the stock list")
        XCTAssertEqual(warehouse.putVerb, "received")
        XCTAssertEqual(warehouse.putThere, "put in the warehouse")
        XCTAssertEqual(warehouse.takenVerb, "sold or used")
        XCTAssertEqual(warehouse.takenFrom, "taken from the warehouse")
        XCTAssertEqual(warehouse.usualFigure, "par level")
        XCTAssertEqual(warehouse.setByOffice, "the office")
        XCTAssertEqual(warehouse.setByList, "this warehouse")
        XCTAssertEqual(warehouse.handover, "send the stock list")
        XCTAssertEqual(warehouse.title, "Warehouse stock")
    }

    func testTheNeutralKindNamesNoPlace() {
        let stock = StockPlaceWording(.stock)
        XCTAssertEqual(stock.location, "in stock")
        XCTAssertEqual(stock.list, "the stock list")
        XCTAssertEqual(stock.putVerb, "received")
        XCTAssertEqual(stock.putThere, "put into stock")
        XCTAssertEqual(stock.takenVerb, "used or sold")
        XCTAssertEqual(stock.takenFrom, "taken from stock")
        XCTAssertEqual(stock.usualFigure, "par level")
        XCTAssertEqual(stock.setByOffice, "the office")
        XCTAssertEqual(stock.setByList, "this list")
        XCTAssertEqual(stock.handover, "send the stock list")
        XCTAssertEqual(stock.title, "Stock")
    }

    func testPremisesNeverBorrowAVehiclesWords() {
        for kind in StockPlace.Kind.allCases where kind.family == .premises {
            for phrase in StockPlaceWording(kind).allPhrases {
                let lower = phrase.lowercased()
                for word in ["van", "truck", "base", "standard load", "load"] {
                    XCTAssertFalse(lower.contains(word), "\(kind): \"\(phrase)\" says \(word)")
                }
            }
        }
    }

    func testVehiclesNeverSayPar() {
        for kind in StockPlace.Kind.allCases where kind.family == .vehicle {
            for phrase in StockPlaceWording(kind).allPhrases {
                XCTAssertFalse(phrase.lowercased().contains("par"), "\(kind): \"\(phrase)\"")
                XCTAssertFalse(phrase.lowercased().contains("store"), "\(kind): \"\(phrase)\"")
                XCTAssertFalse(phrase.lowercased().contains("warehouse"), "\(kind): \"\(phrase)\"")
            }
        }
    }

    func testTheNeutralKindHasNoPlaceNounAnywhere() {
        for phrase in StockPlaceWording(.stock).allPhrases {
            let lower = phrase.lowercased()
            for noun in ["van", "truck", "store", "warehouse", "shop", "base"] {
                XCTAssertFalse(lower.contains(noun), "\"\(phrase)\" names a place: \(noun)")
            }
        }
    }

    func testAVanNeverSaysAnotherKindsNoun() {
        for phrase in StockPlaceWording(.van).allPhrases {
            XCTAssertFalse(phrase.lowercased().contains("store"), phrase)
            XCTAssertFalse(phrase.lowercased().contains("warehouse"), phrase)
        }
    }

    func testEveryPhraseIsSetAndAPlacesWordingFollowsItsKind() {
        for kind in StockPlace.Kind.allCases {
            let wording = StockPlaceWording(kind)
            XCTAssertEqual(wording.family, kind.family)
            XCTAssertEqual(wording.allPhrases.count, 11)
            XCTAssertFalse(wording.allPhrases.contains { $0.isEmpty }, "\(kind)")
            XCTAssertEqual(StockPlace(kind: kind, name: "Somewhere").wording, wording)
        }
    }
}
