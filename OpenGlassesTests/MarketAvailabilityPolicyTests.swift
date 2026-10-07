import XCTest
@testable import OpenGlasses

/// Plan HP P1 item 6 — the storefront boundary, built dormant and armed for face recognition from
/// 2 December 2027 by Plan HS P1 item 1. The other tests switch a restriction on through the
/// injectable table to show the boundary works whatever the shipped table holds.
final class MarketAvailabilityPolicyTests: XCTestCase {

    private typealias Policy = MarketAvailabilityPolicy

    private let now = Date(timeIntervalSince1970: 1_791_000_000)   // October 2026
    private var past: Date { now.addingTimeInterval(-86_400) }
    private var future: Date { now.addingTimeInterval(86_400) }

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

    // MARK: - The shipped table (Plan HS P1 item 1)

    /// 2 December 2027 00:00 UTC, built independently of the policy's own constant.
    private var annexIIIDay: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2027, month: 12, day: 2))!
    }

    func testOnlyFaceRecognitionIsArmedAndForTheDayAnnexIIIApplies() {
        XCTAssertEqual(Set(Policy.restrictedInEEAFrom.keys), Set(Policy.Capability.allCases),
                       "every capability has a row to fill in")
        XCTAssertEqual(Policy.restrictedInEEAFrom[.faceRecognition] ?? nil, annexIIIDay)
        XCTAssertEqual(Policy.annexIIIApplies, annexIIIDay)
        XCTAssertEqual(annexIIIDay.timeIntervalSince1970, 1_827_705_600, "2027-12-02T00:00:00Z")
        XCTAssertNil(Policy.restrictedInEEAFrom[.emotionInference] ?? nil)
        XCTAssertNil(Policy.restrictedInEEAFrom[.firstAidTriageBusiness] ?? nil)
    }

    /// Today (October 2026) nothing is restricted anywhere.
    func testTheShippedTableRestrictsNothingToday() {
        for capability in Policy.Capability.allCases {
            for storefront in ["FR", "DE", "NO", "GB", "US", nil] as [String?] {
                XCTAssertEqual(Policy.availability(of: capability, storefront: storefront, at: now), .available)
            }
        }
    }

    func testFaceRecognitionIsAvailableTheDayBeforeAndUnavailableFromTheDay() {
        let dayBefore = annexIIIDay.addingTimeInterval(-86_400)
        let lastSecond = annexIIIDay.addingTimeInterval(-1)
        let unavailable = Policy.Availability.unavailableInRegion(reason: Policy.reason(for: .faceRecognition))
        for storefront in ["DE", "IE", "NO", "fr"] {
            XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: storefront, at: dayBefore), .available)
            XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: storefront, at: lastSecond), .available)
            XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: storefront, at: annexIIIDay),
                           unavailable, storefront)
            XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: storefront,
                                               at: annexIIIDay.addingTimeInterval(86_400 * 365)), unavailable)
        }
        for storefront in ["GB", "CH", "US", "NZ", nil] as [String?] {
            XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: storefront, at: annexIIIDay),
                           .available, storefront ?? "nil")
        }
        XCTAssertEqual(Policy.availability(of: .emotionInference, storefront: "DE", at: annexIIIDay), .available)
        XCTAssertEqual(Policy.availability(of: .firstAidTriageBusiness, storefront: "DE", at: annexIIIDay), .available)
    }

    // MARK: - The boundary, switched on

    func testANilStorefrontIsAvailableEvenWhenRestricted() {
        let table: [Policy.Capability: Date?] = [.faceRecognition: past]
        XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: nil, at: now, restrictions: table),
                       .available)
    }

    func testARestrictionInThePastMakesItUnavailableInTheEEA() {
        let table: [Policy.Capability: Date?] = [.faceRecognition: past]
        let availability = Policy.availability(of: .faceRecognition, storefront: "FR", at: now, restrictions: table)
        XCTAssertEqual(availability, .unavailableInRegion(reason: Policy.reason(for: .faceRecognition)))
        XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: "NO", at: now, restrictions: table),
                       .unavailableInRegion(reason: Policy.reason(for: .faceRecognition)))
        // Only the restricted capability, and only in the EEA.
        XCTAssertEqual(Policy.availability(of: .emotionInference, storefront: "FR", at: now, restrictions: table),
                       .available)
        XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: "GB", at: now, restrictions: table),
                       .available)
        XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: "CH", at: now, restrictions: table),
                       .available)
    }

    func testTheRestrictionAppliesFromItsDateExactly() {
        let table: [Policy.Capability: Date?] = [.emotionInference: now]
        XCTAssertNotEqual(Policy.availability(of: .emotionInference, storefront: "DE", at: now, restrictions: table),
                          .available)
        XCTAssertEqual(Policy.availability(of: .emotionInference, storefront: "DE",
                                           at: now.addingTimeInterval(-1), restrictions: table), .available)
    }

    func testARestrictionInTheFutureIsStillAvailable() {
        let table: [Policy.Capability: Date?] = [.firstAidTriageBusiness: future]
        XCTAssertEqual(Policy.availability(of: .firstAidTriageBusiness, storefront: "IT", at: now, restrictions: table),
                       .available)
    }

    func testAnUnknownCountryIsAvailable() {
        let table: [Policy.Capability: Date?] = [.faceRecognition: past]
        for storefront in ["ZZ", "XK", "FRA", "123"] {
            XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: storefront, at: now,
                                               restrictions: table), .available, storefront)
        }
    }

    func testEveryReasonResolvesAndNamesNoInternalLabel() {
        for capability in Policy.Capability.allCases {
            let reason = Policy.reason(for: capability)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(reason.contains("region"), reason)
            for token in ["Plan", "HP", "EEA", "Annex", "_"] {
                XCTAssertFalse(reason.contains(token), "\(capability): \(reason)")
            }
        }
    }

    // MARK: - The storefront seam

    private struct FakeStorefrontReader: StorefrontReader {
        let code: String?
        func countryCode() async -> String? { code }
    }

    func testAReaderFeedsThePolicy() async {
        let table: [Policy.Capability: Date?] = [.faceRecognition: past]
        let french = await FakeStorefrontReader(code: "FR").countryCode()
        XCTAssertNotEqual(Policy.availability(of: .faceRecognition, storefront: french, at: now, restrictions: table),
                          .available)
        let unknown = await FakeStorefrontReader(code: nil).countryCode()
        XCTAssertEqual(Policy.availability(of: .faceRecognition, storefront: unknown, at: now, restrictions: table),
                       .available)
    }

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
