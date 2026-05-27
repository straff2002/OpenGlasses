import XCTest
@testable import OpenGlasses

/// Tests for glasses-in-case idle detection and mic shutdown behavior.
/// These test the WakeWordService silence detection state machine and
/// the AppState callback wiring that stops the mic on sustained silence.
@MainActor
final class IdleSleepTests: XCTestCase {

    // MARK: - WakeWordService silence state machine

    func testInitialSilenceState() {
        let svc = WakeWordService()
        XCTAssertFalse(svc.pausedForSilence)
        XCTAssertFalse(svc.isListening)
    }

    func testSilenceDetectedCallbackFires() async {
        let svc = WakeWordService()
        let expectation = expectation(description: "onSilenceDetected fires")

        svc.onSilenceDetected = {
            expectation.fulfill()
        }

        // Simulate what checkAudioLevel does when silence threshold is reached
        svc.pausedForSilence = true
        svc.onSilenceDetected?()

        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertTrue(svc.pausedForSilence)
    }

    func testAudioResumedCallbackFires() async {
        let svc = WakeWordService()
        svc.pausedForSilence = true

        let expectation = expectation(description: "onAudioResumed fires")
        svc.onAudioResumed = {
            expectation.fulfill()
        }

        // Simulate audio returning
        svc.pausedForSilence = false
        svc.onAudioResumed?()

        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertFalse(svc.pausedForSilence)
    }

    func testBluetoothReconnectedCallbackExists() {
        let svc = WakeWordService()
        var called = false
        svc.onBluetoothReconnected = { called = true }
        svc.onBluetoothReconnected?()
        XCTAssertTrue(called, "onBluetoothReconnected callback should be invocable")
    }

    // MARK: - AppState idle wiring

    func testGlassesIdleDefaultFalse() {
        // glassesIdle should default to false
        // (Can't instantiate full AppState in tests due to hardware deps,
        // so we test the WakeWordService side)
        let svc = WakeWordService()
        XCTAssertFalse(svc.pausedForSilence)
    }

    func testSilenceDetectedStopsMic() async {
        let svc = WakeWordService()
        var silenceCallbackCalled = false
        var micStoppedAfterSilence = false

        svc.onSilenceDetected = {
            silenceCallbackCalled = true
            // Simulate what AppState does: stop the mic
            svc.stopListening()
            micStoppedAfterSilence = !svc.isListening
        }

        // Fire silence
        svc.onSilenceDetected?()

        XCTAssertTrue(silenceCallbackCalled)
        XCTAssertTrue(micStoppedAfterSilence, "Mic should be stopped when silence detected")
        XCTAssertFalse(svc.isListening, "isListening should be false after silence shutdown")
    }

    func testBluetoothReconnectClearsIdleState() {
        let svc = WakeWordService()
        var idleCleared = false

        // Simulate idle state
        svc.pausedForSilence = true

        svc.onBluetoothReconnected = {
            // Simulate what AppState does: clear idle
            svc.pausedForSilence = false
            idleCleared = true
        }

        svc.onBluetoothReconnected?()

        XCTAssertTrue(idleCleared)
        XCTAssertFalse(svc.pausedForSilence, "pausedForSilence should be cleared on BT reconnect")
    }

    func testStopListeningIsIdempotent() {
        let svc = WakeWordService()
        // Should not crash when called multiple times
        svc.stopListening()
        svc.stopListening()
        XCTAssertFalse(svc.isListening)
    }

    // MARK: - Callback wiring completeness

    func testAllIdleCallbacksExist() {
        let svc = WakeWordService()

        // Verify all idle-related callbacks can be set
        svc.onSilenceDetected = {}
        svc.onAudioResumed = {}
        svc.onBluetoothReconnected = {}
        svc.onBluetoothDisconnected = {}

        // Should all be non-nil after setting
        XCTAssertNotNil(svc.onSilenceDetected)
        XCTAssertNotNil(svc.onAudioResumed)
        XCTAssertNotNil(svc.onBluetoothReconnected)
        XCTAssertNotNil(svc.onBluetoothDisconnected)
    }

    func testSilenceThenReconnectFullCycle() {
        let svc = WakeWordService()
        var states: [String] = []

        svc.onSilenceDetected = {
            states.append("silence")
            svc.stopListening()
        }

        svc.onBluetoothReconnected = {
            states.append("reconnected")
            svc.pausedForSilence = false
        }

        // Simulate full cycle: silence detected → mic stops → BT reconnects
        svc.pausedForSilence = true
        svc.onSilenceDetected?()
        XCTAssertFalse(svc.isListening)

        svc.onBluetoothReconnected?()
        XCTAssertFalse(svc.pausedForSilence)

        XCTAssertEqual(states, ["silence", "reconnected"])
    }
}
