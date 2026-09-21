import XCTest
@testable import OpenGlasses

/// Whether the root tab bar carries a Job tab (Plan FO P2).
///
/// Pure — no view is built and no service is stood up. The whole point of `JobTabPresence` is that
/// the matrix a screen recording could never cover is a table here: every combination of the
/// wearer's switch, the entitlement, whether the entitlement has been *asked* yet, and whether a
/// job is open.
final class JobTabPresenceTests: XCTestCase {

    private func decide(enabled: Bool = false, entitled: Bool = false,
                        checked: Bool = false, openJob: Bool = false) -> JobTabPresence.Decision {
        JobTabPresence.decide(.init(featureEnabled: enabled, entitled: entitled,
                                    entitlementChecked: checked, hasOpenJob: openJob))
    }

    // MARK: - Nobody without Field Assist ever sees it

    func testHiddenWithTheFeatureSwitchedOff() {
        XCTAssertEqual(decide(enabled: false, entitled: false, checked: true), .hidden)
        // Even entitled: the wearer's own switch is off, and that is a definite answer.
        XCTAssertEqual(decide(enabled: false, entitled: true, checked: true), .hidden)
    }

    /// The switch alone is enough to answer "no" — no store round trip, so a consumer never sees a
    /// tab appear a second after launch.
    func testTheSwitchAnswersWithoutWaitingForTheStore() {
        XCTAssertEqual(decide(enabled: false, entitled: false, checked: false), .hidden)
    }

    func testHiddenWhenEntitlementWasCheckedAndRefused() {
        XCTAssertEqual(decide(enabled: true, entitled: false, checked: true), .hidden)
    }

    // MARK: - Unchecked is not the same as unentitled

    /// The cold-launch case. `hasCheckedEntitlements` is false until the store check has run, so a
    /// false `entitled` means *unknown* — and a tab drawn on that guess would be a fifth tab in
    /// front of somebody who never bought anything.
    func testUncheckedEntitlementIsUndeterminedRatherThanHidden() {
        XCTAssertEqual(decide(enabled: true, entitled: false, checked: false), .undetermined)
    }

    func testUndeterminedDrawsNoTab() {
        XCTAssertFalse(decide(enabled: true, entitled: false, checked: false).showsTab)
        XCTAssertFalse(JobTabPresence.Decision.hidden.showsTab)
        XCTAssertTrue(JobTabPresence.Decision.shown.showsTab)
    }

    /// A signed organisation licence verifies synchronously, so it arrives already granted and
    /// never waits on the store check.
    func testALicenceGrantShowsTheTabWithoutTheStoreCheck() {
        XCTAssertEqual(decide(enabled: true, entitled: true, checked: false), .shown)
    }

    // MARK: - Entitled

    func testShownWhenEntitledAndSwitchedOn() {
        XCTAssertEqual(decide(enabled: true, entitled: true, checked: true), .shown)
    }

    // MARK: - An open job outranks the entitlement

    /// A licence that lapses mid-visit must not take the job away with it: the technician still has
    /// to close it, read it back and send it.
    func testALicenceLapsingMidJobKeepsTheTab() {
        XCTAssertEqual(decide(enabled: true, entitled: false, checked: true, openJob: true), .shown)
    }

    /// Including when the wearer's own switch went off underneath it.
    func testAnOpenJobKeepsTheTabEvenWithTheFeatureSwitchedOff() {
        XCTAssertEqual(decide(enabled: false, entitled: false, checked: true, openJob: true), .shown)
    }

    /// And at cold launch, before the entitlement has been asked about at all — a restored job is
    /// a job.
    func testAnOpenJobShowsTheTabBeforeTheEntitlementResolves() {
        XCTAssertEqual(decide(enabled: true, entitled: false, checked: false, openJob: true), .shown)
    }

    // MARK: - The bar it produces

    func testTabsWithoutTheJobTabAreTheFourThatShipped() {
        XCTAssertEqual(JobTabPresence.tabs(for: .hidden), [.voice, .modes, .chat, .settings])
        XCTAssertEqual(JobTabPresence.tabs(for: .undetermined), [.voice, .modes, .chat, .settings])
    }

    func testTabsWithTheJobTabPutItBetweenChatAndSettings() {
        XCTAssertEqual(JobTabPresence.tabs(for: .shown), [.voice, .modes, .chat, .job, .settings])
    }

    // MARK: - The selection when it goes away

    func testSelectionFallsBackToVoiceWhenTheJobTabGoes() {
        XCTAssertEqual(JobTabPresence.selection(.job, after: .hidden), .voice)
        XCTAssertEqual(JobTabPresence.selection(.job, after: .undetermined), .voice)
    }

    func testSelectionIsLeftAloneWhileTheJobTabIsThere() {
        XCTAssertEqual(JobTabPresence.selection(.job, after: .shown), .job)
    }

    /// The tab appearing or disappearing must never move anybody who was not on it. A bar that
    /// reshuffled the wearer's place because an entitlement resolved in the background would be
    /// worse than the missing tab.
    func testNoOtherTabIsEverBounced() {
        for tab in MainTab.allCases where tab != .job {
            for decision: JobTabPresence.Decision in [.shown, .hidden, .undetermined] {
                XCTAssertEqual(JobTabPresence.selection(tab, after: decision), tab,
                               "\(tab) moved when the Job tab became \(decision)")
            }
        }
    }
}
