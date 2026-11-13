import XCTest
@testable import OpenGlasses

/// Plan HP P1 item 6 — the storefront facts: the EEA list, StoreKit's codes and the support
/// report's line. The per-capability gate went with face recognition on 2026-11-13.
final class MarketAvailabilityPolicyTests: XCTestCase {

    private typealias Policy = MarketAvailabilityPolicy

    // MARK: - The EEA list

    func testTheEEAIsTheEU27PlusIcelandLiechtensteinAndNorway() {
        XCTAssertEqual(Policy.eeaStorefronts.count, 30)
        for code in ["FR", "DE", "IE", "GR", "HU", "MT", "CY", "HR", "SE", "PL"] {
            XCTAssertTrue(Policy.isEEA(code), code)
        }
        for code in ["IS", "LI", "NO"] {
            XCTAssertTrue(Policy.isEEA(code), "\(code) is in the EEA though not the EU")
        }
    }

    func testBritainAndSwitzerlandAreNotInTheEEA() {
        for code in ["GB", "CH", "US", "NZ", "EL", "UK"] {
            XCTAssertFalse(Policy.isEEA(code), code)
        }
        XCTAssertFalse(Policy.isEEA(nil))
        XCTAssertFalse(Policy.isEEA(""))
        XCTAssertTrue(Policy.isEEA(" fr "), "case and whitespace do not matter")
    }

    // MARK: - The storefront seam

    /// StoreKit reports alpha-3; every EEA storefront converts to the alpha-2 the policy holds, so
    /// the conversion can never make an EEA storefront look foreign.
    func testStoreKitCodesConvertToAlpha2ForEveryEEAStorefront() {
        let converted = Set(StoreKitStorefrontReader.alpha3ToAlpha2.values)
        XCTAssertTrue(Policy.eeaStorefronts.isSubset(of: converted),
                      "unmapped: \(Policy.eeaStorefronts.subtracting(converted).sorted())")
        XCTAssertEqual(StoreKitStorefrontReader.alpha2(fromStoreKit: "FRA"), "FR")
        XCTAssertEqual(StoreKitStorefrontReader.alpha2(fromStoreKit: "grc"), "GR")
        XCTAssertEqual(StoreKitStorefrontReader.alpha2(fromStoreKit: "NOR"), "NO")
        XCTAssertEqual(StoreKitStorefrontReader.alpha2(fromStoreKit: "GBR"), "GB")
        XCTAssertEqual(StoreKitStorefrontReader.alpha2(fromStoreKit: "CHE"), "CH")
        XCTAssertFalse(Policy.isEEA(StoreKitStorefrontReader.alpha2(fromStoreKit: "GBR")))
        XCTAssertEqual(StoreKitStorefrontReader.alpha2(fromStoreKit: "BRA"), "BRA", "unmapped passes through")
        XCTAssertNil(StoreKitStorefrontReader.alpha2(fromStoreKit: " "))
    }

    func testTheSupportReportLine() {
        XCTAssertEqual(Policy.supportReportLine(storefront: "NZ"), "App Store region: NZ")
        XCTAssertEqual(Policy.supportReportLine(storefront: nil), "App Store region: unknown")
    }
}
