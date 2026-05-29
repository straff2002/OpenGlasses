import XCTest
@testable import OpenGlasses

/// Tests the Plan M3 audio-session coordinator state machine. The real audio side-effects are behind
/// the injected control protocol, so transitions/idempotency are unit-testable.
@MainActor
final class ExpertCallAudioCoordinatorTests: XCTestCase {

    private final class RecordingControl: ExpertCallAudioControlling {
        private(set) var events: [String] = []
        func pauseVoicePipeline() { events.append("pause") }
        func resumeVoicePipeline() { events.append("resume") }
    }

    private func makeCoordinator() -> (ExpertCallAudioCoordinator, RecordingControl) {
        let coordinator = ExpertCallAudioCoordinator()
        let control = RecordingControl()
        coordinator.control = control
        return (coordinator, control)
    }

    func testBeginPausesVoicePipeline() {
        let (c, control) = makeCoordinator()
        c.beginCall()
        XCTAssertTrue(c.isCallActive)
        XCTAssertEqual(control.events, ["pause"])
    }

    func testEndResumesVoicePipeline() {
        let (c, control) = makeCoordinator()
        c.beginCall()
        c.endCall()
        XCTAssertFalse(c.isCallActive)
        XCTAssertEqual(control.events, ["pause", "resume"])
    }

    func testBeginIsIdempotent() {
        let (c, control) = makeCoordinator()
        c.beginCall()
        c.beginCall()
        XCTAssertEqual(control.events, ["pause"], "Second begin should be a no-op")
    }

    func testEndWhenInactiveIsNoOp() {
        let (c, control) = makeCoordinator()
        c.endCall()
        XCTAssertFalse(c.isCallActive)
        XCTAssertEqual(control.events, [])
    }

    func testReentrantCallCycle() {
        let (c, control) = makeCoordinator()
        c.beginCall(); c.endCall()
        c.beginCall(); c.endCall()
        XCTAssertEqual(control.events, ["pause", "resume", "pause", "resume"])
        XCTAssertFalse(c.isCallActive)
    }
}
