import XCTest
@testable import OpenGlasses

/// Plan HS P1 item 1 — the storefront, read once per launch and answered synchronously after. No
/// StoreKit: the reader is injected.
///
/// This class also covered the storefront gate for face recognition, which went with the feature
/// on 2026-11-13; what remains is the read itself, which the refrigeration units' regional default
/// still depends on.
@MainActor
final class MarketAvailabilityTests: XCTestCase {

    private struct FakeStorefrontReader: StorefrontReader {
        let code: String?
        func countryCode() async -> String? { code }
    }

    private func service(_ code: String?) -> MarketAvailability {
        MarketAvailability(reader: FakeStorefrontReader(code: code))
    }

    func testTheStorefrontIsReadOnce() async {
        let market = service("DE")
        XCTAssertNil(market.storefront, "unknown until the read lands")
        await market.refresh()
        XCTAssertEqual(market.storefront, "DE")
        await market.refresh()
        XCTAssertEqual(market.storefront, "DE")
    }

    /// TestFlight sandboxes and signed-out phones report no storefront: it stays unknown.
    func testANilStorefrontStaysUnknown() async {
        let market = service(nil)
        await market.refresh()
        XCTAssertNil(market.storefront)
    }
}
