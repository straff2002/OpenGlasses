import XCTest
@testable import OpenGlasses

/// Whether "Record this job" is offered and may be used, and the sentence given when it may not.
final class JobRecordingAvailabilityTests: XCTestCase {
    private typealias A = JobRecordingAvailability

    /// Everything in favour: an office, an open job with no recording, nothing forbidding it.
    private func ready(_ change: (inout A.Facts) -> Void = { _ in }) -> A.Facts {
        var facts = A.Facts(officeTransportInBuild: true, fieldAssistEntitled: true, officeBindingCurrent: true,
                            organizationForbidsRecording: false, organizationRequiresBlur: false,
                            medicalComplianceMode: false, officeRouteRefused: false, jobIsOpen: true,
                            jobAlreadyRecorded: false, unsyncedBytes: 0)
        change(&facts)
        return facts
    }

    func testWithAnOfficeAnOpenJobAndNothingInTheWayItIsAvailable() {
        XCTAssertEqual(A.evaluate(ready()), .available)
        XCTAssertTrue(A.evaluate(ready()).isAvailable)
        XCTAssertEqual(A.reasons(ready()), [])
        XCTAssertNil(A.mustStop(ready()))
    }

    // MARK: - No office, no recording

    func testWithoutAnOfficeTheOptionIsNotOfferedAtAll() {
        XCTAssertEqual(A.evaluate(ready { $0.officeTransportInBuild = false }), .notOffered)
        XCTAssertEqual(A.evaluate(ready { $0.fieldAssistEntitled = false }), .notOffered)
        XCTAssertEqual(A.evaluate(ready { $0.officeBindingCurrent = false }), .notOffered)
    }

    func testNotOfferedWinsOverEveryReason() {
        let facts = ready {
            $0.officeBindingCurrent = false
            $0.organizationForbidsRecording = true
            $0.medicalComplianceMode = true
        }
        XCTAssertEqual(A.evaluate(facts), .notOffered)
    }

    // MARK: - Each thing in the way

    func testEachThingInTheWayRefusesWithItsOwnReason() {
        XCTAssertEqual(A.evaluate(ready { $0.medicalComplianceMode = true }), .unavailable(.medicalComplianceMode))
        XCTAssertEqual(A.evaluate(ready { $0.officeRouteRefused = true }), .unavailable(.officeRouteRefused))
        XCTAssertEqual(A.evaluate(ready { $0.organizationForbidsRecording = true }), .unavailable(.forbiddenByOrganization))
        XCTAssertEqual(A.evaluate(ready { $0.organizationRequiresBlur = true }), .unavailable(.blurRequiredButNotPossible))
        XCTAssertEqual(A.evaluate(ready { $0.jobIsOpen = false }), .unavailable(.noOpenJob))
        XCTAssertEqual(A.evaluate(ready { $0.jobAlreadyRecorded = true }), .unavailable(.alreadyRecorded))
    }

    /// With blur required and no way to blur, nothing is recorded — rather than recorded and
    /// sent, or recorded and held. A blur pass is not assumed: unless the caller says one is
    /// there, the rule is one that cannot be met.
    func testBlurRequiredMeansNoRecordingWhereTheAppCannotBlur() {
        let facts = ready { $0.organizationRequiresBlur = true }
        XCTAssertFalse(facts.blurPassAvailable, "not available unless the caller says a blur pass is there")
        XCTAssertEqual(A.evaluate(facts), .unavailable(.blurRequiredButNotPossible))
        XCTAssertEqual(A.mustStop(facts), .blurRequiredButNotPossible)
        let sentence = A.Reason.blurRequiredButNotPossible.explanation
        XCTAssertTrue(sentence.contains("blurred") && sentence.contains("can't be recorded"), sentence)
    }

    /// With the blur pass there, an organisation that requires blur can record: the recording is
    /// blurred on the phone before it is sealed. Nothing else about availability changes.
    func testAnOrganisationThatRequiresBlurCanRecordWhereTheAppCanBlur() {
        let facts = ready {
            $0.organizationRequiresBlur = true
            $0.blurPassAvailable = true
        }
        XCTAssertEqual(A.evaluate(facts), .available)
        XCTAssertEqual(A.reasons(facts), [])
        XCTAssertNil(A.mustStop(facts), "and a recording already running is not stopped by the rule")

        // A blur pass with no rule to meet changes nothing.
        XCTAssertEqual(A.evaluate(ready { $0.blurPassAvailable = true }), .available)

        // Everything else stands in the way exactly as before.
        func blurring(_ change: (inout A.Facts) -> Void) -> A.Facts {
            ready {
                $0.organizationRequiresBlur = true
                $0.blurPassAvailable = true
                change(&$0)
            }
        }
        XCTAssertEqual(A.evaluate(blurring { $0.officeBindingCurrent = false }), .notOffered)
        XCTAssertEqual(A.evaluate(blurring { $0.medicalComplianceMode = true }), .unavailable(.medicalComplianceMode))
        XCTAssertEqual(A.evaluate(blurring { $0.officeRouteRefused = true }), .unavailable(.officeRouteRefused))
        XCTAssertEqual(A.evaluate(blurring { $0.organizationForbidsRecording = true }), .unavailable(.forbiddenByOrganization))
        XCTAssertEqual(A.evaluate(blurring { $0.jobIsOpen = false }), .unavailable(.noOpenJob))
        XCTAssertEqual(A.evaluate(blurring { $0.jobAlreadyRecorded = true }), .unavailable(.alreadyRecorded))
        XCTAssertEqual(A.evaluate(blurring { $0.unsyncedBytes = .max }), .unavailable(.unsyncedLimitReached))
        XCTAssertEqual(A.mustStop(blurring { $0.organizationForbidsRecording = true }), .forbiddenByOrganization)
    }

    // MARK: - The limit on what is waiting

    func testAtTheLimitOnUnsentRecordingsANewOneIsRefusedWithWhatToDo() {
        let limits = RetentionDecision.Limits.standard
        XCTAssertEqual(A.evaluate(ready { $0.unsyncedBytes = limits.unsyncedBytes - 1 }), .available)
        XCTAssertEqual(A.evaluate(ready { $0.unsyncedBytes = limits.unsyncedBytes }), .unavailable(.unsyncedLimitReached))
        XCTAssertEqual(A.Reason.unsyncedLimitReached.explanation, RetentionDecision.unsyncedLimitNote)
        XCTAssertEqual(RetentionDecision.mayStartRecording(unsyncedBytes: limits.unsyncedBytes),
                       .refused(RetentionDecision.unsyncedLimitNote))
        XCTAssertTrue(RetentionDecision.unsyncedLimitNote.contains("Wi-Fi"))
    }

    // MARK: - Which reason is named

    func testWhenSeveralThingsAreInTheWayTheyAreNamedInOrder() {
        let everything = ready {
            $0.medicalComplianceMode = true
            $0.officeRouteRefused = true
            $0.organizationForbidsRecording = true
            $0.organizationRequiresBlur = true
            $0.jobIsOpen = false
            $0.jobAlreadyRecorded = true
            $0.unsyncedBytes = .max
        }
        XCTAssertEqual(A.reasons(everything), A.Reason.allCases)
        XCTAssertEqual(A.evaluate(everything), .unavailable(.medicalComplianceMode))
    }

    // MARK: - A recording already running

    func testARunningRecordingStopsWhenSomethingItMayNotRunUnderComesIntoForce() {
        XCTAssertEqual(A.mustStop(ready { $0.medicalComplianceMode = true }), .medicalComplianceMode)
        XCTAssertEqual(A.mustStop(ready { $0.officeRouteRefused = true }), .officeRouteRefused)
        XCTAssertEqual(A.mustStop(ready { $0.organizationForbidsRecording = true }), .forbiddenByOrganization)
    }

    func testARunningRecordingIsNotStoppedByWhatOnlyMattersAtTheStart() {
        // Its own job is the one it is recording, and it is itself what is waiting.
        XCTAssertNil(A.mustStop(ready {
            $0.jobAlreadyRecorded = true
            $0.unsyncedBytes = .max
        }))
    }

    // MARK: - Plain words

    func testEveryReasonIsASentenceForATechnician() {
        var seen: Set<String> = []
        for reason in A.Reason.allCases {
            let sentence = reason.explanation
            XCTAssertTrue(seen.insert(sentence).inserted, "two reasons with the same words: \(sentence)")
            XCTAssertTrue(sentence.first?.isUppercase == true && sentence.hasSuffix("."), sentence)
            for token in ["Plan", "HE ", "P1", "P2", "FX", "HIPAA", "bundle", "binding", "ceiling", "_"] {
                XCTAssertFalse(sentence.contains(token), "\(sentence) — \(token)")
            }
        }
    }
}
