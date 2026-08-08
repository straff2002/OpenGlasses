import XCTest
import AVFoundation
@testable import OpenGlasses

/// Plan BE (docs/plans/BE-wake-word-hardening.md): the headless-testable pieces — the audio-thread
/// silence tracker, the lock-guarded tap-state box, and the on-device recognition flag. (Live
/// wake-word accuracy and audio-session recovery are device-pending by house style.)
final class WakeWordHardeningTests: XCTestCase {

    // MARK: - SilenceTracker

    func testSilenceTrackerReportsEnteredSilenceOnceAtLimit() {
        let tracker = SilenceTracker()
        // Below-threshold buffers accumulate; the transition fires exactly at the limit.
        for i in 1..<3 {
            XCTAssertEqual(tracker.observe(rms: 0.0, threshold: 0.005, limit: 3), .none, "buffer \(i)")
        }
        guard case .enteredSilence(let count) = tracker.observe(rms: 0.0, threshold: 0.005, limit: 3) else {
            return XCTFail("third silent buffer should cross the limit")
        }
        XCTAssertEqual(count, 3)
        // Further silence does not re-report.
        XCTAssertEqual(tracker.observe(rms: 0.0, threshold: 0.005, limit: 3), .none)
    }

    func testSilenceTrackerReportsResumeOnlyAfterSilence() {
        let tracker = SilenceTracker()
        // Loud from the start → no resume event (never was silent).
        XCTAssertEqual(tracker.observe(rms: 1.0, threshold: 0.005, limit: 3), .none)

        for _ in 0..<3 { _ = tracker.observe(rms: 0.0, threshold: 0.005, limit: 3) }
        XCTAssertEqual(tracker.observe(rms: 1.0, threshold: 0.005, limit: 3), .resumed)
        // Second loud buffer is not another resume.
        XCTAssertEqual(tracker.observe(rms: 1.0, threshold: 0.005, limit: 3), .none)
    }

    func testSilenceTrackerResetClearsState() {
        let tracker = SilenceTracker()
        for _ in 0..<3 { _ = tracker.observe(rms: 0.0, threshold: 0.005, limit: 3) }
        tracker.reset()
        // After reset, a loud buffer should NOT report a resume (we're back to silence-clear).
        XCTAssertEqual(tracker.observe(rms: 1.0, threshold: 0.005, limit: 3), .none)
    }

    // MARK: - WakeTapState (data-race surface)

    func testTapStateDispatchesToForwardersUnderConcurrentMutation() {
        let box = WakeTapState()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256

        // `nonisolated(unsafe)`: `NSCountedSet` isn't `Sendable`, and the forwarders below are
        // `@Sendable` closures called from a background queue. Every touch is `lock`-guarded —
        // which is the point of the test — so the unsafety is the discipline, not a hole.
        nonisolated(unsafe) let received = NSCountedSet()
        let lock = NSLock()
        box.setForwarders(["a": { _ in lock.lock(); received.add("a"); lock.unlock() }])

        // Hammer dispatch from one queue while another swaps forwarders — must not crash and must
        // keep delivering. (Under TSAN this is the regression guard for the tap/main-actor race.)
        let dispatchExp = expectation(description: "dispatch")
        let mutateExp = expectation(description: "mutate")
        DispatchQueue.global().async {
            for _ in 0..<2000 { box.dispatch(buffer) }
            dispatchExp.fulfill()
        }
        DispatchQueue.global().async {
            for i in 0..<2000 {
                box.setForwarders(["a": { _ in lock.lock(); received.add("a"); lock.unlock() },
                                   "b\(i % 3)": { _ in }])
            }
            mutateExp.fulfill()
        }
        wait(for: [dispatchExp, mutateExp], timeout: 10)
        XCTAssertGreaterThan(received.count(for: "a"), 0, "forwarder should have received buffers")
    }

    func testTapStateNilRequestIsSafe() {
        let box = WakeTapState()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        buffer.frameLength = 128
        box.setRequest(nil)
        box.setForwarders([:])
        box.dispatch(buffer)   // no request, no forwarders → must be a safe no-op
    }

    // MARK: - Config flag

    func testOnDeviceWakeWordDefaultsOn() {
        UserDefaults.standard.removeObject(forKey: "onDeviceWakeWordEnabled")
        XCTAssertTrue(Config.onDeviceWakeWordEnabled)
    }

    func testOnDeviceWakeWordTogglePersists() {
        defer { UserDefaults.standard.removeObject(forKey: "onDeviceWakeWordEnabled") }
        Config.setOnDeviceWakeWordEnabled(false)
        XCTAssertFalse(Config.onDeviceWakeWordEnabled)
        Config.setOnDeviceWakeWordEnabled(true)
        XCTAssertTrue(Config.onDeviceWakeWordEnabled)
    }
}
