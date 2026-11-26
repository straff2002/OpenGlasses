import XCTest
@testable import OpenGlasses

/// Plan NH §2 — each exemption alone, and combined. The baseline is a store build with nothing
/// paid and nothing on, which is the one case that is metered.
final class AllowanceExemptionTests: XCTestCase {

    private var metered: AllowanceExemption.Inputs {
        var inputs = AllowanceExemption.Inputs()
        inputs.isStoreBuild = true
        return inputs
    }

    func testAStoreBuildWithNothingPaidIsMetered() {
        XCTAssertFalse(AllowanceExemption.isExempt(metered))
        XCTAssertEqual(AllowanceExemption.reasons(metered), [])
    }

    func testEachExemptionAlone() {
        let cases: [(WritableKeyPath<AllowanceExemption.Inputs, Bool>, AllowanceExemption.Reason)] = [
            (\.standardActive, .paidTier),
            (\.myManualsActive, .paidTier),
            (\.fieldAssistGranted, .paidTier),
            (\.medicalActive, .paidTier),
            (\.organisationProfile, .paidTier),
            (\.purchasesUnread, .purchasesUnread),
            (\.voiceOverRunning, .accessibility),
            (\.accessibilityModeOn, .accessibility),
            (\.assistiveModeActive, .accessibility),
            (\.firstAidTurn, .firstAid),
            (\.firstAidSessionActive, .firstAid),
        ]
        for (key, reason) in cases {
            var inputs = metered
            inputs[keyPath: key] = true
            XCTAssertTrue(AllowanceExemption.isExempt(inputs), "\(key)")
            XCTAssertEqual(AllowanceExemption.reasons(inputs), [reason], "\(key)")
        }
    }

    func testTestFlightAndXcodeBuildsAreUnmeteredUnlessTheDeveloperSettingIsOn() {
        var inputs = AllowanceExemption.Inputs()
        inputs.isStoreBuild = false
        XCTAssertEqual(AllowanceExemption.reasons(inputs), [.unmeteredBuild])
        inputs.meterAsStoreBuild = true
        XCTAssertFalse(AllowanceExemption.isExempt(inputs), "metered as a store build")
        inputs.isStoreBuild = true
        XCTAssertFalse(AllowanceExemption.isExempt(inputs), "the setting changes nothing on a store build")
    }

    func testCombinedExemptionsReportEveryReasonInOrder() {
        var inputs = AllowanceExemption.Inputs()
        inputs.standardActive = true
        inputs.fieldAssistGranted = true
        inputs.voiceOverRunning = true
        inputs.firstAidTurn = true
        XCTAssertEqual(AllowanceExemption.reasons(inputs), [.paidTier, .accessibility, .firstAid, .unmeteredBuild])
        XCTAssertTrue(AllowanceExemption.isExempt(inputs))
    }

    func testMeteringATestBuildDoesNotUndoAnyOtherExemption() {
        var inputs = AllowanceExemption.Inputs()
        inputs.meterAsStoreBuild = true
        inputs.accessibilityModeOn = true
        XCTAssertEqual(AllowanceExemption.reasons(inputs), [.accessibility])
        inputs.accessibilityModeOn = false
        inputs.firstAidSessionActive = true
        XCTAssertEqual(AllowanceExemption.reasons(inputs), [.firstAid])
    }
}
