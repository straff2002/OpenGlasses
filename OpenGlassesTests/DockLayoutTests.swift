import XCTest
@testable import OpenGlasses

final class DockLayoutTests: XCTestCase {

    func testEmptyStoredYieldsCanonical() {
        XCTAssertEqual(DockLayout.effectiveOrder(stored: []), DockLayout.canonical)
        XCTAssertEqual(DockLayout.decode(""), DockLayout.canonical)
    }

    func testStoredOrderWinsAndMissingItemsAppendCanonically() {
        // User moved mic mode first and disconnect second; everything they
        // never touched follows in shipped order.
        let order = DockLayout.effectiveOrder(stored: ["micMode", "disconnect"])
        XCTAssertEqual(Array(order.prefix(2)), [.micMode, .disconnect])
        XCTAssertEqual(
            Array(order.dropFirst(2)),
            DockLayout.canonical.filter { $0 != .micMode && $0 != .disconnect }
        )
        XCTAssertEqual(Set(order), Set(DockItem.allCases))
    }

    func testStaleAndDuplicateIdentifiersAreDropped() {
        let order = DockLayout.effectiveOrder(
            stored: ["camera", "retiredButton", "camera", "model"])
        XCTAssertEqual(Array(order.prefix(2)), [.camera, .model])
        XCTAssertEqual(order.count, DockItem.allCases.count)
    }

    func testEncodeDecodeRoundTrip() {
        let shuffled: [DockItem] = [.disconnect, .camera, .model, .quickActions,
                                    .preview, .type, .micMode, .assistive]
        XCTAssertEqual(DockLayout.decode(DockLayout.encode(shuffled)), shuffled)
    }
}
