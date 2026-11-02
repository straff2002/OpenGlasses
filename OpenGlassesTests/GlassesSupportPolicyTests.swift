import XCTest
@testable import OpenGlasses

/// Plan JE — the store copy offers no glasses; every other copy does. The install channel is the
/// only input, so the whole rule is a table.
final class GlassesSupportPolicyTests: XCTestCase {

    override func tearDown() {
        GlassesSupportPolicy.overrideForTesting = nil
        super.tearDown()
    }

    func testOnlyThePhoneVariantExcludesGlassesRegardlessOfTheReceipt() {
        XCTAssertEqual(GlassesSupportPolicy.verdict(variant: .phoneOnly), .notInThisVersion)
        XCTAssertEqual(GlassesSupportPolicy.verdict(variant: .glassesBeta), .supported)
    }

    func testTheReasonNamesTheAppAndNoPlan() {
        let reason = GlassesSupportPolicy.unavailableReason(appName: "Avenkin")
        #if AVENKIN_PHONE_ONLY
        XCTAssertEqual(reason, "That isn't available in this version of Avenkin.")
        #else
        XCTAssertEqual(reason, "Smart glasses aren't supported in this version of Avenkin.")
        #endif
        XCTAssertFalse(reason.contains("JE"), "plan letters never reach a rendered string")
        XCTAssertFalse(reason.lowercased().contains("meta"),
                       "the store copy does not explain Meta's release channel to a store user")
    }

    func testTheOverrideDecidesCurrentAndIsSupported() {
        GlassesSupportPolicy.overrideForTesting = .notInThisVersion
        XCTAssertEqual(GlassesSupportPolicy.current, .notInThisVersion)
        XCTAssertFalse(GlassesSupportPolicy.isSupported)
        #if AVENKIN_PHONE_ONLY
        XCTAssertEqual(GlassesSupportPolicy.reportLine, "Build variant: phone-only")
        #else
        XCTAssertEqual(GlassesSupportPolicy.reportLine, "Build variant: \(AppBuildVariant.current.rawValue) · Glasses: not in this version (phone-only build)")
        #endif

        GlassesSupportPolicy.overrideForTesting = .supported
        XCTAssertEqual(GlassesSupportPolicy.isSupported, AppBuildVariant.current == .glassesBeta)
        if AppBuildVariant.current == .glassesBeta {
            XCTAssertEqual(GlassesSupportPolicy.reportLine, "Build variant: glasses-beta · Glasses: offered by this copy")
        }
    }

    /// The test host is the simulator (or a development build under testability), never a store
    /// install: without an override the glasses are offered, which is what every other glasses test
    /// in this bundle assumes.
    func testTheTestHostOffersGlasses() {
        GlassesSupportPolicy.overrideForTesting = nil
        XCTAssertEqual(GlassesSupportPolicy.isSupported, AppBuildVariant.current == .glassesBeta)
    }
}
