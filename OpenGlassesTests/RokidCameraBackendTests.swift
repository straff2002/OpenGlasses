import XCTest
@testable import OpenGlasses

/// Plan AH P2 — the Rokid camera backend, tested against a mock transport (no hardware, no SDK).
@MainActor
final class RokidCameraBackendTests: XCTestCase {

    private final class MockCameraTransport: RokidCameraTransporting {
        var isConnected = false
        var onDisconnect: ((Error?) -> Void)?
        var stillResult: Result<Data, Error> = .failure(RokidCameraError.stillUnavailable)
        func connect() async throws { isConnected = true }
        func disconnect() { isConnected = false }
        func captureStill() async throws -> Data { try stillResult.get() }
    }

    func testCameraBackendChoiceDisplayNames() {
        XCTAssertEqual(CameraBackendChoice.metaRayBan.displayName, "Ray-Ban Meta")
        XCTAssertEqual(CameraBackendChoice.rokidRV101.displayName, "Rokid RV101")
        XCTAssertEqual(CameraBackendChoice(rawValue: "rokidRV101"), .rokidRV101)
    }

    func testCapabilitiesAreHonest() {
        let backend = RokidCameraBackend(transport: MockCameraTransport())
        XCTAssertFalse(backend.capabilities.liveFrames)
        XCTAssertTrue(backend.capabilities.stillCapture)
        XCTAssertEqual(backend.capabilities.stillLatency, .seconds)
        XCTAssertFalse(backend.capabilities.hardwareEvents)
    }

    func testIsReadyRequiresConnectedTransport() {
        let transport = MockCameraTransport()
        let backend = RokidCameraBackend(transport: transport)
        XCTAssertFalse(backend.isReady(configuringIfNeeded: false))
        transport.isConnected = true
        XCTAssertTrue(backend.isReady(configuringIfNeeded: false))
    }

    func testEnsurePermissionRequiresGrant() async {
        let denied = RokidCameraBackend(transport: MockCameraTransport(), permissionGranted: false)
        do {
            try await denied.ensurePermission()
            XCTFail("expected throw")
        } catch let error as RokidCameraError {
            XCTAssertEqual(error, .permissionNotGranted)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let granted = RokidCameraBackend(transport: MockCameraTransport(), permissionGranted: true)
        try? await granted.ensurePermission()
    }

    func testCapturePhotoReturnsTransportBytes() async throws {
        let transport = MockCameraTransport()
        transport.isConnected = true
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        transport.stillResult = .success(bytes)
        let backend = RokidCameraBackend(transport: transport, permissionGranted: true)
        let captured = try await backend.capturePhoto()
        XCTAssertEqual(captured, bytes)
    }

    func testCapturePhotoThrowsWhenStillUnavailable() async {
        let transport = MockCameraTransport()
        transport.isConnected = true
        transport.stillResult = .failure(RokidCameraError.stillUnavailable)
        let backend = RokidCameraBackend(transport: transport, permissionGranted: true)
        do {
            _ = try await backend.capturePhoto()
            XCTFail("expected throw")
        } catch let error as RokidCameraError {
            XCTAssertEqual(error, .stillUnavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCapturePhotoThrowsWhenDisconnected() async {
        let backend = RokidCameraBackend(transport: MockCameraTransport(), permissionGranted: true)
        do {
            _ = try await backend.capturePhoto()
            XCTFail("expected throw")
        } catch let error as RokidCameraError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStartStreamingThrowsLiveFramesUnavailable() async {
        let backend = RokidCameraBackend(transport: MockCameraTransport())
        do {
            try await backend.startStreaming()
            XCTFail("expected throw")
        } catch let error as RokidCameraError {
            XCTAssertEqual(error, .liveFramesUnavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
