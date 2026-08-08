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

    /// Recording and broadcast are deliberately uncovered in v1 (30 fps needs an off-main pipeline
    /// that does not exist yet). Asserted rather than left implicit so that when someone builds
    /// that pipeline, this test fails and reminds them to update the Settings copy too.
    func testRecordingAndBroadcastAreNotYetCovered() {
        XCTAssertFalse(PrivacyFilterScope.recording.isFiltered)
        XCTAssertFalse(PrivacyFilterScope.broadcast.isFiltered)
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
