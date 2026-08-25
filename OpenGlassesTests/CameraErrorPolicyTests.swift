import MWDATCamera
import XCTest
@testable import OpenGlasses

/// Tests the pure typed-error policy that replaced string-matching on DAT camera errors and decides
/// when a pending photo capture should fail fast (DAT 0.8.0 unified `DatError` model). All
/// `StreamError` cases are constructible without touching `Wearables` (`DeviceIdentifier` is a String).
final class CameraErrorPolicyTests: XCTestCase {

    /// Cases that should abandon a pending capture immediately (the photo won't arrive).
    private let terminal: [StreamError] = [
        .hingesClosed, .timeout, .thermalCritical, .thermalEmergency,
        .peakPowerShutdown, .batteryCritical, .permissionDenied,
        .deviceNotConnected("dev"), .deviceNotFound("dev"),
    ]
    /// Transient cases where the capture or the timeout backstop may still resolve.
    private let transient: [StreamError] = [.internalError, .videoStreamingError]

    func testTerminalErrorsAbortCapture() {
        for error in terminal {
            XCTAssertTrue(CameraErrorPolicy.abortsCapture(error), "\(error) should abort a pending capture")
        }
    }

    func testTransientErrorsDoNotAbortCapture() {
        for error in transient {
            XCTAssertFalse(CameraErrorPolicy.abortsCapture(error), "\(error) should not abort a pending capture")
        }
    }

    func testEveryErrorHasANonEmptyMessage() {
        for error in terminal + transient {
            XCTAssertFalse(CameraErrorPolicy.message(for: error).isEmpty, "\(error) should map to a message")
        }
    }

    /// A warmup wait aborts on exactly the errors that mean `start()` already failed — more nudges
    /// replay the same cycle, and only the caller can rebuild the stream. This is deliberately the
    /// inverse of the capture decision for these two cases.
    func testStartFailuresAbortAWarmupWait() {
        for error in transient {
            XCTAssertTrue(CameraErrorPolicy.abortsWarmup(error), "\(error) should abort a warmup wait")
            XCTAssertFalse(CameraErrorPolicy.abortsCapture(error), "\(error) should not abort a pending capture")
        }
    }

    /// Terminal conditions stay bounded by the timeout rather than aborting warmup: whether they
    /// also arrive transiently during the cold-start churn is unverified, and an over-eager abort
    /// would break the healthy slow start the full window exists to protect.
    func testTerminalErrorsDoNotAbortAWarmupWait() {
        for error in terminal {
            XCTAssertFalse(CameraErrorPolicy.abortsWarmup(error), "\(error) should not abort a warmup wait")
        }
    }

    /// Regression guard for the whole point of the abort: a warmup window shorter than the longest
    /// healthy cold start makes every healthy cold start fail its first attempt and rebuild.
    func testWarmupWindowClearsTheObservedColdStart() {
        XCTAssertGreaterThanOrEqual(StreamRecoveryPolicy.warmupTimeout,
                                    StreamRecoveryPolicy.observedColdStart,
                                    "a healthy cold start must fit inside a single warmup attempt")
    }

    func testMessagesAreSpecificForKeyConditions() {
        XCTAssertTrue(CameraErrorPolicy.message(for: .hingesClosed).localizedCaseInsensitiveContains("hinge"))
        XCTAssertTrue(CameraErrorPolicy.message(for: .thermalCritical).localizedCaseInsensitiveContains("hot"))
        XCTAssertTrue(CameraErrorPolicy.message(for: .batteryCritical).localizedCaseInsensitiveContains("battery"))
        XCTAssertTrue(CameraErrorPolicy.message(for: .permissionDenied).localizedCaseInsensitiveContains("permission"))
    }
}
