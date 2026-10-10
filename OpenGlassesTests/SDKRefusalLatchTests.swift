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

        await service.stopStreaming()
        await service.tearDown()
        XCTAssertEqual(backend.stopStreamingCount, 1, "stopping is always forwarded")
        XCTAssertEqual(backend.tearDownCount, 1)

        // With the glasses away the capture is the phone's, and the latch is about the glasses.
        service.isGlassesLinkUp = { false }
        _ = try await service.capturePhoto()
        XCTAssertEqual(phone.captureCount, 1)
        XCTAssertEqual(backend.captureCount, 0)
    }
}
