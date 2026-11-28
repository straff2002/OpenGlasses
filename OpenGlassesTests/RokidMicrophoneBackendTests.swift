import XCTest
@testable import OpenGlasses

/// Covers the microphone seam's honest capability declaration and the frame hand-off, with a mock
/// transport. Nothing here opens an `AVAudioSession` or touches hardware.
@MainActor
final class RokidMicrophoneBackendTests: XCTestCase {

    /// A transport that records calls and lets the test push frames.
    @MainActor
    private final class MockTransport: RokidAudioTransporting {
        var isConnected = false
        var onAudioFrame: ((Data) -> Void)?
        var onDisconnect: ((Error?) -> Void)?
        private(set) var connectCalls = 0
        private(set) var disconnectCalls = 0

        func connect() async throws {
            connectCalls += 1
            isConnected = true
        }

        func disconnect() {
            disconnectCalls += 1
            isConnected = false
        }
    }

    // MARK: - Capabilities

    func testCapabilitiesAreHonestAboutTheNativeStream() {
        let backend = RokidMicrophoneBackend(transport: MockTransport())
        let capabilities = backend.capabilities

        // The ARTC/Ai stream is not implemented; saying otherwise would be the lie this seam exists
        // to prevent.
        XCTAssertFalse(capabilities.streamsWearerAudio)
        XCTAssertFalse(capabilities.liveStream)
        // ...but the Bluetooth headset route is real and used today.
        XCTAssertTrue(capabilities.routesViaBluetoothHFP)
        XCTAssertEqual(capabilities.encoding, .opus16kMono)
    }

    func testUnavailableCapabilitiesDeclareNothing() {
        XCTAssertFalse(MicrophoneCapabilities.unavailable.streamsWearerAudio)
        XCTAssertFalse(MicrophoneCapabilities.unavailable.routesViaBluetoothHFP)
    }

    // MARK: - Availability

    func testIsAvailableFollowsPairingConfig() {
        let saved = Config.rokidPeripheralID
        defer { Config.rokidPeripheralID = saved }

        // `rokidPairingConfigured` is "the default has been written at all", so the unpaired
        // state is `nil`, not the empty string.
        Config.rokidPeripheralID = nil
        let backend = RokidMicrophoneBackend(transport: MockTransport())
        XCTAssertFalse(backend.isAvailable)

        Config.rokidPeripheralID = "TEST-PAIRED-DEVICE"
        XCTAssertTrue(backend.isAvailable)
    }

    // MARK: - Start / stop

    func testStartCaptureRefusesWhileTheStreamIsDark() async {
        let transport = MockTransport()
        let backend = RokidMicrophoneBackend(transport: transport)

        do {
            try await backend.startCapture()
            XCTFail("startCapture should refuse while the native stream is dark")
        } catch let error as RokidMicrophoneError {
            XCTAssertEqual(error, .streamUnavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // The refusal must also mean "do not touch the transport".
        XCTAssertEqual(transport.connectCalls, 0)
    }

    func testStopCaptureDisconnectsTransport() async {
        let transport = MockTransport()
        let backend = RokidMicrophoneBackend(transport: transport)

        await backend.stopCapture()
        XCTAssertEqual(transport.disconnectCalls, 1)
    }

    // MARK: - Frame hand-off

    func testFramesFromTransportReachTheConsumer() {
        let transport = MockTransport()
        let backend = RokidMicrophoneBackend(transport: transport)

        var received: [Data] = []
        backend.onAudioFrame = { received.append($0) }

        transport.onAudioFrame?(Data([0x4F, 0x50, 0x55, 0x53]))

        XCTAssertEqual(received, [Data([0x4F, 0x50, 0x55, 0x53])])
    }

    func testTransportDisconnectSurfacesAsAnError() {
        let transport = MockTransport()
        let backend = RokidMicrophoneBackend(transport: transport)

        var surfaced: Error?
        backend.onError = { surfaced = $0 }

        transport.onDisconnect?(nil)

        XCTAssertEqual(surfaced as? RokidMicrophoneError, .notConnected)
    }

    // MARK: - Errors

    func testErrorMessagesNameTheWayForward() {
        XCTAssertEqual(
            RokidMicrophoneError.streamUnavailable.errorDescription?.contains("Bluetooth headset"),
            true
        )
        XCTAssertEqual(RokidMicrophoneError.notPaired.errorDescription?.contains("paired"), true)
    }
}
