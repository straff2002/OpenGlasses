import MWDATCore
import XCTest
@testable import OpenGlasses

@MainActor
final class CameraSessionStartupFailureTests: XCTestCase {
    override func tearDown() {
        NoticeCenter.shared.clear(source: .camera)
        super.tearDown()
    }

    func testSDKStartupReasonsRemainDistinctWithoutLoggingPayloads() {
        let unavailable = DeviceSessionError.unexpectedError(description: "Device unavailable")
        let ended = DeviceSessionError.unexpectedError(description: "Session ended by device")
        XCTAssertEqual(DeviceSessionFailureReason(unavailable), .deviceUnavailable)
        XCTAssertEqual(DeviceSessionFailureReason(ended), .sessionEndedByDevice)
        XCTAssertEqual(DeviceSessionFailureReason(DeviceSessionError.dwaUnavailable), .developerAppUnavailable)
        XCTAssertEqual(SafeErrorSummary(unavailable).description, "cannotConnect(deviceUnavailable)")
        XCTAssertEqual(SafeErrorSummary(ended).description, "cannotConnect(sessionEndedByDevice)")
        XCTAssertEqual(SafeErrorSummary(DeviceSessionFailureReason.recoveryError(unavailable)), SafeErrorSummary(unavailable))

        let unknown = DeviceSessionError.unexpectedError(description: "Device unavailable https://private.example/?token=canary")
        XCTAssertNil(DeviceSessionFailureReason(unknown), "only exact known descriptions are public")
        XCTAssertFalse(SafeErrorSummary(unknown).description.contains("canary"))
        XCTAssertNil(DeviceSessionFailureReason(DeviceSessionError.noEligibleDevice), "ordinary discovery retries are unchanged")
    }

    func testRefusalsHaveBoundedRecoveryAndSpeakableSteps() {
        XCTAssertEqual(DeviceSessionFailureReason.deviceUnavailable.maximumStartAttempts, 2)
        XCTAssertEqual(DeviceSessionFailureReason.sessionEndedByDevice.maximumStartAttempts, 2)
        XCTAssertEqual(DeviceSessionFailureReason.developerAppUnavailable.maximumStartAttempts, 1)
        XCTAssertEqual(CameraErrorPolicy.retryDisposition(for: DeviceSessionError.dwaUnavailable),
                       .stopRetrying(notice: DeviceSessionFailureReason.developerAppUnavailable.notice))
        for reason in [DeviceSessionFailureReason.deviceUnavailable, .sessionEndedByDevice, .developerAppUnavailable] {
            XCTAssertTrue(SpokenErrorPolicy.looksHuman(reason.notice), "recovery steps must survive the spoken-error gate")
        }
        XCTAssertTrue(DeviceSessionFailureReason.deviceUnavailable.notice.contains("apply"))
        XCTAssertTrue(DeviceSessionFailureReason.sessionEndedByDevice.notice.contains("case"))
    }

    func testFailedCameraClaimStopsConnectingAndSuppliesTheLivePrompt() async throws {
        let backend = MockCameraBackend()
        backend.startError = CameraError.sessionUnavailable(.deviceUnavailable)
        let service = CameraService(backend: backend, phoneCamera: MockPhoneCamera())
        do {
            try await service.claimStream(for: .liveSession)
            XCTFail("a failed camera must not be claimed")
        } catch {
            XCTAssertEqual(error.localizedDescription, DeviceSessionFailureReason.deviceUnavailable.notice)
        }
        XCTAssertFalse(service.holdsStreamClaim(.liveSession))
        XCTAssertFalse(service.isStartingStream)
        XCTAssertFalse(service.readinessNow.userWantsStream)
        XCTAssertEqual(service.readinessNow.phase, .stopped)
        let notice = try XCTUnwrap(service.streamingFailureNotice)
        let instruction = LiveCameraFailureInstruction.unavailable(reason: notice)
        XCTAssertTrue(instruction.contains("Camera startup failed"))
        XCTAssertTrue(instruction.contains("apply its settings to the glasses"))
        XCTAssertFalse(instruction.contains("try again in a moment"))

        backend.startError = nil
        try await service.claimStream(for: .liveSession)
        XCTAssertNil(service.streamingFailureNotice, "successful retry must retract the old failure")
        await service.releaseStream(for: .liveSession)
    }

    func testAnUnknownCameraStatusDoesNotPromiseItIsConnecting() {
        let instruction = LiveCameraFailureInstruction.unavailable(reason: nil)
        XCTAssertTrue(instruction.contains("No camera images are available"))
        XCTAssertFalse(instruction.contains("The camera is still connecting"))
        XCTAssertTrue(instruction.contains("If images arrive later"), "a setup failure must not permanently disable vision")
    }

    func testUnknownSDKPayloadCannotReachLiveModelInstructions() async {
        let backend = MockCameraBackend()
        backend.startError = DeviceSessionError.unexpectedError(description: "private-payload-canary")
        let service = CameraService(backend: backend, phoneCamera: MockPhoneCamera())
        do { try await service.startStreaming() } catch {}
        XCTAssertNotNil(service.streamingFailureNotice)
        XCTAssertFalse(LiveCameraFailureInstruction.unavailable(reason: service.streamingFailureNotice)
            .contains("private-payload-canary"))
    }

    func testCameraTransportCapabilitiesAreInTheAuthoredEntitlements() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("OpenGlasses/OpenGlasses.entitlements"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["com.apple.developer.networking.HotspotConfiguration"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.developer.networking.wifi-info"] as? Bool, true)
    }
}
