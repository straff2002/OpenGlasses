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
