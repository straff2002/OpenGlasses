import MWDATCore
import XCTest
@testable import OpenGlasses

/// Plan HX P1 — glasses that refuse this build are asked once per process, not once per start.
///
/// The pure latch first, then the coordinator through the fake backend: the real one cannot run
/// here (`Wearables` traps in a unit-test process), and what matters is on this side of the seam
/// anyway. A latched refusal must stop the coordinator *calling* the backend.
@MainActor
final class SDKRefusalLatchTests: XCTestCase {

    private let appUpdate = DATCompatibilityMessage.appUpdateRequired

    override func tearDown() {
        // The coordinator posts compatibility notices to the shared surface.
        NoticeCenter.shared.clear(source: .glasses)
        super.tearDown()
    }

    // MARK: - The latch

    func testAFreshLatchLetsStartsThrough() {
        let latch = SDKRefusalLatch()
        XCTAssertFalse(latch.isLatched)
        XCTAssertNil(latch.startRefusal)
    }

    func testARefusalLatchesWithTheAppUpdateSentence() {
        var latch = SDKRefusalLatch()
        XCTAssertTrue(latch.latch(), "this is the call that latched")
        XCTAssertTrue(latch.isLatched)
        XCTAssertEqual(latch.startRefusal, appUpdate)
    }

    func testASecondReportChangesNothing() {
        var latch = SDKRefusalLatch()
        latch.latch()
        let once = latch
        XCTAssertFalse(latch.latch())
        XCTAssertEqual(latch, once)
        XCTAssertEqual(latch.startRefusal, appUpdate)
    }

    func testOnlyInsufficientSDKVersionIsARefusalOfTheBuild() {
        XCTAssertTrue(DATCompatibilityMessage.isSDKRefusal(.insufficientSDKVersion))
        let others: [DeviceSessionError] = [
            // The glasses-side app is the wearer's to update; a nonblocking warning is nothing.
            .datAppOnTheGlassesUpdateRequired, .dwaOutOfStuRange, .dwaUnavailable,
            .noEligibleDevice, .sessionAlreadyStopped, .sessionAlreadyExists, .sessionIdle,
            .capabilityAlreadyActive, .capabilityNotFound, .unexpectedError(description: "x"),
            .thermalCritical, .thermalEmergency, .peakPowerShutdown, .batteryCritical,
        ]
        for error in others {
            XCTAssertFalse(DATCompatibilityMessage.isSDKRefusal(error), "\(error)")
        }
    }

    func testThePerCycleClearLeavesTheRefusalAndClearsEverythingElse() {
        var latch = SDKRefusalLatch()
        XCTAssertNil(latch.notice(afterBackendReported: nil), "unlatched, a clear is a clear")
        XCTAssertEqual(latch.notice(afterBackendReported: "Update the glasses app"), "Update the glasses app")

        latch.latch()
        XCTAssertEqual(latch.notice(afterBackendReported: nil), appUpdate, "the refusal stands")
        XCTAssertEqual(latch.notice(afterBackendReported: "Update the glasses app"), "Update the glasses app",
                       "what the backend says now is still shown as said")
    }

    // MARK: - Through the coordinator

    private func makeService() -> (CameraService, MockCameraBackend, MockPhoneCamera) {
        let backend = MockCameraBackend(isReady: true)
        // Not decodable as an image on purpose: keeps the photo-library write out of a unit test.
        backend.captureResult = .success(Data([0xDE, 0xAD]))
        let phone = MockPhoneCamera()
        return (CameraService(backend: backend, phoneCamera: phone), backend, phone)
    }

    private func assertRefused(_ work: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await work()
            XCTFail("expected the start to be refused", file: file, line: line)
        } catch CameraError.incompatible(let message) {
            XCTAssertEqual(message, appUpdate, file: file, line: line)
        } catch {
            XCTFail("refused with the wrong error: \(type(of: error))", file: file, line: line)
        }
    }

    func testUnlatchedStartsReachTheBackend() async throws {
        let (service, backend, _) = makeService()
        _ = try await service.startStreaming()
        _ = try await service.capturePhoto()
        XCTAssertEqual(backend.startStreamingCount, 1)
        XCTAssertEqual(backend.captureCount, 1)
        XCTAssertFalse(service.sdkRefusal.isLatched)
    }

    func testARefusedSessionFailsTheNextStreamStartWithoutASessionAttempt() async {
        let (service, backend, _) = makeService()
        backend.events.send(.sdkRefused)
        XCTAssertTrue(service.sdkRefusal.isLatched)

        await assertRefused { _ = try await service.startStreaming() }
        await assertRefused { _ = try await service.startStreaming() }
        XCTAssertEqual(backend.startStreamingCount, 0, "the backend must not be asked for a session")
        XCTAssertFalse(service.isStartingStream)
        XCTAssertEqual(service.scheduledCameraWorkCount, 0, "a refused start leaves nothing armed")
    }

    func testARefusedSessionFailsTheNextCaptureWithoutASessionAttemptOrAPhoneSwap() async {
        let (service, backend, phone) = makeService()
        backend.events.send(.sdkRefused)

        await assertRefused { _ = try await service.capturePhoto() }
        XCTAssertEqual(backend.captureCount, 0, "the backend must not be asked for a session")
        XCTAssertEqual(phone.captureCount, 0,
                       "connected glasses that cannot serve fail; they are not swapped for the phone")
        XCTAssertFalse(service.isCaptureInProgress)
    }

    func testAClaimOnARefusedCameraIsNotHeld() async {
        let (service, backend, _) = makeService()
        backend.events.send(.sdkRefused)

        await assertRefused { try await service.claimStream(for: .liveSession) }
        XCTAssertFalse(service.hasStreamClaims, "a claim on a stream that never came up is not kept")
        XCTAssertEqual(backend.startStreamingCount, 0)
    }

    /// The compatibility notice is copy for the wearer and latches nothing by itself, whatever it
    /// says: only the session's own refusal does.
    func testANoticeAloneLatchesNothing() async throws {
        let (service, backend, _) = makeService()
        backend.events.send(.compatibilityNotice(appUpdate))
        XCTAssertFalse(service.sdkRefusal.isLatched)
        _ = try await service.startStreaming()
        XCTAssertEqual(backend.startStreamingCount, 1)
    }

    func testItSurvivesThePerCycleNoticeClear() async {
        let (service, backend, _) = makeService()
        // What the real backend does when a session is refused: the notice, then the refusal.
        backend.events.send(.compatibilityNotice(appUpdate))
        backend.events.send(.sdkRefused)
        XCTAssertEqual(service.compatibilityNotice, appUpdate)

        // The top of the next session cycle.
        backend.events.send(.compatibilityNotice(nil))
        XCTAssertEqual(service.compatibilityNotice, appUpdate, "the refusal is not a per-cycle notice")
        XCTAssertTrue(service.sdkRefusal.isLatched)
        await assertRefused { _ = try await service.startStreaming() }
        await assertRefused { _ = try await service.capturePhoto() }
        XCTAssertEqual(backend.startStreamingCount, 0)
        XCTAssertEqual(backend.captureCount, 0)
    }

    func testThePerCycleClearStillClearsEveryOtherNotice() async throws {
        let (service, backend, _) = makeService()
        backend.events.send(.compatibilityNotice("Update the glasses app"))
        XCTAssertEqual(service.compatibilityNotice, "Update the glasses app")
        backend.events.send(.compatibilityNotice(nil))
        XCTAssertNil(service.compatibilityNotice)
        XCTAssertFalse(service.sdkRefusal.isLatched, "an ordinary notice latches nothing")
        _ = try await service.startStreaming()
        XCTAssertEqual(backend.startStreamingCount, 1)

        // And once latched, another notice is shown while it stands and gives way to the
        // refusal when the backend takes it back.
        backend.events.send(.sdkRefused)
        backend.events.send(.compatibilityNotice("Update the glasses app"))
        XCTAssertEqual(service.compatibilityNotice, "Update the glasses app")
        backend.events.send(.compatibilityNotice(nil))
        XCTAssertEqual(service.compatibilityNotice, appUpdate)
    }

    func testALatchedRefusalDoesNotStopAStopOrThePhoneCamera() async throws {
        let (service, backend, phone) = makeService()
        backend.events.send(.sdkRefused)
        await service.sdkRefusalStandDown?.value   // the latch's own stop, counted below

        await service.stopStreaming()
        await service.tearDown()
        XCTAssertEqual(backend.stopStreamingCount, 2, "stopping is always forwarded")
        XCTAssertEqual(backend.tearDownCount, 1)

        // With the glasses away the capture is the phone's, and the latch is about the glasses.
        service.isGlassesLinkUp = { false }
        _ = try await service.capturePhoto()
        XCTAssertEqual(phone.captureCount, 1)
        XCTAssertEqual(backend.captureCount, 0)
    }

    // MARK: - Terminal for the camera's own retries too (follow-up)

    func testOnlyARefusalOfTheBuildEndsTheRetries() {
        guard case .incompatible(let message)? =
                SDKRefusalLatch.terminalError(for: DeviceSessionError.insufficientSDKVersion) else {
            return XCTFail("a refused build must end the camera's retries")
        }
        XCTAssertEqual(message, appUpdate, "the attempt that met the refusal reads like every later one")

        // Everything else is a window that closes, or the wearer's to fix: another attempt may work.
        let retried: [Error] = [
            DeviceSessionError.datAppOnTheGlassesUpdateRequired, DeviceSessionError.dwaOutOfStuRange,
            DeviceSessionError.noEligibleDevice, DeviceSessionError.sessionAlreadyExists,
            DeviceSessionError.capabilityAlreadyActive, DeviceSessionError.thermalCritical,
            DeviceSessionError.unexpectedError(description: "x"),
            CameraError.streamNotReady, CameraError.captureFailed, CancellationError(),
        ]
        for error in retried {
            XCTAssertNil(SDKRefusalLatch.terminalError(for: error), "\(error)")
            XCTAssertFalse(DATCompatibilityMessage.isSDKRefusal(error), "\(error)")
        }
        XCTAssertTrue(DATCompatibilityMessage.isSDKRefusal(DeviceSessionError.insufficientSDKVersion as Error),
                      "the refusal is still recognised once its type has been erased by a throw")
    }

    /// A reconnect ladder or a stall recovery lives in the backend, and climbs for a stream that
    /// was running. The refusal must stop it the way a wearer's Stop does.
    func testARefusalUnderARunningStreamStopsTheCamera() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        _ = try await service.startStreaming()
        XCTAssertTrue(service.isStreaming)
        XCTAssertTrue(service.readiness.userWantsStream)

        backend.events.send(.sdkRefused)
        await service.sdkRefusalStandDown?.value

        XCTAssertEqual(backend.stopStreamingCount, 1, "the backend was not told to stop its own work")
        XCTAssertFalse(service.isStreaming)
        XCTAssertFalse(service.readiness.userWantsStream, "nothing is wanted from refused glasses")
        XCTAssertEqual(service.scheduledCameraWorkCount, 0)
        XCTAssertNil(service.sdkRefusalStandDown)
    }

    /// While a reconnect climbs the coordinator believes nothing is running, and that is exactly
    /// when the backend has a ladder armed. The stop is sent whatever this side believes.
    func testTheStopIsSentEvenWhenNothingLooksLikeItIsRunning() async {
        let (service, backend, _) = makeService()
        XCTAssertFalse(service.isStreaming)

        backend.events.send(.sdkRefused)
        await service.sdkRefusalStandDown?.value

        XCTAssertEqual(backend.stopStreamingCount, 1)
    }

    func testASecondReportDoesNotStopTwice() async {
        let (service, backend, _) = makeService()
        // The real backend reports from two places: the failed start and the session's error stream.
        backend.events.send(.sdkRefused)
        backend.events.send(.sdkRefused)
        await service.sdkRefusalStandDown?.value
        backend.events.send(.sdkRefused)
        XCTAssertNil(service.sdkRefusalStandDown)

        XCTAssertEqual(backend.stopStreamingCount, 1)
    }

    /// After the stop the latch holds: the stream that was running is the last one asked for,
    /// and a claim on the refused camera is not kept.
    func testNothingStartsAfterARefusalUnderARunningStream() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        _ = try await service.startStreaming()
        backend.events.send(.sdkRefused)
        await service.sdkRefusalStandDown?.value

        await assertRefused { _ = try await service.startStreaming() }
        await assertRefused { try await service.claimStream(for: .liveSession) }
        XCTAssertEqual(backend.startStreamingCount, 1, "only the start from before the refusal")
        XCTAssertFalse(service.hasStreamClaims)
    }

    /// A notice or a compatibility reading stops nothing: only the session's refusal does.
    func testANoticeAloneStopsNothing() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        _ = try await service.startStreaming()

        backend.events.send(.compatibilityNotice(appUpdate))
        await Task.yield()

        XCTAssertNil(service.sdkRefusalStandDown)
        XCTAssertEqual(backend.stopStreamingCount, 0)
        XCTAssertTrue(service.isStreaming)
    }

    // MARK: - The retries that cannot run here

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    /// The Meta backend's source with whole-line `//` comments dropped.
    private func backendCode() throws -> String {
        let path = "OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift"
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func slice(of code: String, from opening: String, to closing: String,
                       _ what: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: opening), "the backend no longer has \(what)")
        let rest = code[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: closing), "could not find the end of \(what)")
        return rest[..<end.lowerBound]
    }

    /// A stream start makes two warm-up attempts. The second must not be made for refused glasses.
    func testAWarmUpThatMetTheRefusalIsNotRetried() throws {
        let warmUp = try slice(of: try backendCode(), from: "private func warmUpStream() async throws {",
                               to: "\n    }\n", "`warmUpStream()`")
        let refusal = try XCTUnwrap(
            warmUp.range(of: "if let refusal = SDKRefusalLatch.terminalError(for: error) { throw refusal }"),
            "a stream start asks refused glasses for a second session again")
        let retry = try XCTUnwrap(warmUp.range(of: "guard attempt < 2 else { break }"))
        XCTAssertLessThan(refusal.lowerBound, retry.lowerBound)
    }

    /// The coordinator's stop is what ends the reconnect ladder and the stall detector. Both read
    /// the intent a stop clears, and a stop has to end the detector whether or not a stream is up.
    func testAStopEndsTheLadderAndTheDetectorWhetherOrNotAStreamIsUp() throws {
        let stop = try slice(of: try backendCode(), from: "func stopStreaming() async {",
                             to: "\n    }\n", "`stopStreaming()`")
        let intent = try XCTUnwrap(stop.range(of: "continuousStreamingIntent = false"))
        let ladder = try XCTUnwrap(stop.range(of: "cancelReconnect()"))
        let detector = try XCTUnwrap(stop.range(of: "stopStallDetection()"))
        let guardLine = try XCTUnwrap(stop.range(of: "guard isStreaming else { return }"))
        for step in [intent, ladder, detector] {
            XCTAssertLessThan(step.lowerBound, guardLine.lowerBound,
                              "a stop during a reconnect returns at the guard: everything that "
                                  + "ends the camera's own retries has to come before it")
        }
    }

    /// Both places the backend can meet the refusal still report it.
    func testBothPlacesTheBackendMeetsTheRefusalReportIt() throws {
        let code = try backendCode()
        XCTAssertEqual(code.components(separatedBy: "events.send(.sdkRefused)").count, 3,
                       "the failed session start and the session's error stream")
    }
}
