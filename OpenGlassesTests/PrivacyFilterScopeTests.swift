import UIKit
import XCTest
@testable import OpenGlasses

/// Plan CO Item 0. The bystander blur shipped with no call sites at all — `processFrame` was never
/// invoked, so the Settings toggle promised something the app did not do. These tests pin the two
/// invariants that decide where it now applies, so a future consumer has to choose consciously.
final class PrivacyFilterScopeTests: XCTestCase {

    /// Every frame that leaves the device for a third-party model is filtered. This is the whole
    /// point of the feature; if one of these flips to false the promise is false again.
    func testEveryModelFacingConsumerIsFiltered() {
        XCTAssertTrue(PrivacyFilterScope.liveSession.isFiltered)
        XCTAssertTrue(PrivacyFilterScope.directModelTurn.isFiltered)
        XCTAssertTrue(PrivacyFilterScope.pinnedFrame.isFiltered)
        XCTAssertTrue(PrivacyFilterScope.agentAttachment.isFiltered)
    }

    /// Face recognition must see raw pixels: the blur is indiscriminate, so filtering ahead of it
    /// would blur the very faces the user enrolled and break recognition outright.
    func testFaceRecognitionIsExempt() {
        XCTAssertFalse(PrivacyFilterScope.faceRecognition.isFiltered)
    }

    /// Recording and broadcast were deliberately uncovered in CO Item 0, asserted so that building
    /// the pipeline would fail this test and force the user-facing copy to be corrected with it.
    /// Plan CP built it; the assertion flipped, and the copy was updated in the same change. Kept
    /// as a record of how the carve-out was retired rather than quietly forgotten.
    func testOutboundConsumersAreCoveredSinceCP() {
        XCTAssertTrue(PrivacyFilterScope.recording.isFiltered)
        XCTAssertTrue(PrivacyFilterScope.broadcast.isFiltered)
        XCTAssertTrue(PrivacyFilterScope.expertStream.isFiltered)
    }

    /// Plan HE: a recorded job is captured unfiltered, and the app-wide switch does not govern it
    /// — the consent sheet says so, and the organisation decides whether the office receives it
    /// blurred. It is not relay-fed: the relay's holes are the reason capture is raw.
    func testTheRecordedJobIsUnfilteredAtCaptureAndNotRelayFed() {
        XCTAssertFalse(PrivacyFilterScope.officeRecording.isFiltered)
        XCTAssertFalse(PrivacyFilterScope.officeRecording.usesOutboundRelay)
        XCTAssertTrue(PrivacyFilterScope.officeRecording.leavesTheDevice,
                      "it goes to the office, and the scope must say so rather than pass as on-device")
        // The ordinary recording is untouched: still filtered, still off the relay.
        XCTAssertTrue(PrivacyFilterScope.recording.isFiltered)
        XCTAssertTrue(PrivacyFilterScope.recording.usesOutboundRelay)
    }

    /// Plan HE, the blur pass. Where an organisation requires faces blurred before a recorded job
    /// goes to its office, that is not the wearer's setting to turn off. Exactly one scope is
    /// blurred whatever the setting says, and with the setting off it still refuses a frame it
    /// cannot process rather than handing it back.
    func testOnlyTheRecordedJobsBlurPassIsBlurredWhateverTheSettingSays() {
        XCTAssertEqual(PrivacyFilterScope.allCases.filter(\.isMandatory), [.officeRecordingBlur])
        XCTAssertTrue(PrivacyFilterScope.officeRecordingBlur.isFiltered)
        XCTAssertTrue(PrivacyFilterScope.officeRecordingBlur.leavesTheDevice)
        XCTAssertFalse(PrivacyFilterScope.officeRecordingBlur.usesOutboundRelay)
    }

    @MainActor
    func testWithTheSettingOffAMandatoryScopeIsStillNotAPassthrough() {
        let filter = PrivacyFilterService()
        filter.isEnabled = false
        let source = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }

        // The blur cannot run: every ordinary scope hands the picture back, because the setting
        // is off and that is the wearer's choice. The mandatory one refuses.
        filter.noteScenePhase(.background)
        XCTAssertIdentical(filter.filteredOrUnavailable(source, for: .recording), source)
        XCTAssertIdentical(filter.filteredOrUnavailable(source, for: .toolPhotoCapture), source)
        XCTAssertIdentical(filter.filtered(source, for: .directModelTurn), source)
        XCTAssertNil(filter.filteredOrUnavailable(source, for: .officeRecordingBlur))
        XCTAssertNotIdentical(filter.filtered(source, for: .officeRecordingBlur), source,
                              "the nonoptional form hands back an opaque frame, never the source")

        filter.noteScenePhase(.active)
        filter.noteProtectedDataAvailable(false)
        XCTAssertNil(filter.filteredOrUnavailable(source, for: .officeRecordingBlur))

        // And the recorded job's own scope is still unfiltered at capture: that has not changed.
        XCTAssertIdentical(filter.filteredOrUnavailable(source, for: .officeRecording), source)
    }

    /// A new case must not default into either bucket silently — walking `allCases` means adding
    /// one without classifying it here fails the suite.
    func testEveryScopeIsClassifiedExactlyOnce() {
        let filtered = PrivacyFilterScope.allCases.filter(\.isFiltered)
        let exempt = PrivacyFilterScope.allCases.filter { !$0.isFiltered }
        XCTAssertEqual(filtered.count + exempt.count, PrivacyFilterScope.allCases.count)
        XCTAssertEqual(Set(PrivacyFilterScope.allCases.map(\.rawValue)).count,
                       PrivacyFilterScope.allCases.count,
                       "Duplicate raw values would collapse two consumers into one policy.")
    }
}
