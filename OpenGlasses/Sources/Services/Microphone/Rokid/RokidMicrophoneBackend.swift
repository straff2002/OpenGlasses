import Foundation

/// A microphone stream from Rokid Glasses over CXRService.
///
/// Two paths exist for Rokid audio, and only one of them is ours to take today:
///
/// * **Bluetooth headset — works now.** The glasses pair as an HFP headset, `AVAudioSession` offers
///   their microphone as an input, and the existing listener / transcription pipeline uses it with
///   no protocol work. `capabilities.routesViaBluetoothHFP` reports this honestly, and it is the
///   same path `GlassesTier.audioOnly` describes for every headset-class device.
/// * **ARTC / Ai audio — not implemented.** The device's own microphone sent as framed audio inside
///   the CXRService Caps envelope, which is the family Rokid's own SDK drives. The frame encoding is
///   not public; Meta's protocol shows the shape of the problem
///   (`CaptureNotification.microphoneAudio`: OPUS, 16 kHz mono, ~20 ms), and this backend is built
///   to accept exactly that once the envelope is known.
///
/// Until then the backend ships dark: available when a Rokid device is paired, honest that it cannot
/// stream, and `startCapture()` fails rather than pretending a microphone is open.
@MainActor
protocol RokidAudioTransporting: AnyObject {
    var isConnected: Bool { get }
    func connect() async throws
    func disconnect()
    /// Encoded frames in `MicrophoneCapabilities.encoding`.
    var onAudioFrame: ((Data) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
}

/// Placeholder transport — the ARTC/Ai frame encoding and GATT channel are not public.
///
/// It mirrors `RokidCameraTransport`: the seam is real, the wire is not, and when the envelope is
/// captured from hardware this class is the only file that changes.
@MainActor
final class RokidAudioTransport: RokidAudioTransporting {
    private(set) var isConnected = false
    var onAudioFrame: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    func connect() async throws {
        throw RokidMicrophoneError.notConnected
    }

    func disconnect() {}
}

@MainActor
final class RokidMicrophoneBackend: GlassesMicrophoneBackend {
    /// Honest: the HFP route works today; the ARTC stream does not.
    let capabilities: MicrophoneCapabilities = .bluetoothHeadsetOnly

    private let transport: RokidAudioTransporting

    var isAvailable: Bool { Config.rokidPairingConfigured }
    var onAudioFrame: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    init(transport: RokidAudioTransporting? = nil) {
        // Resolved here rather than as a default argument: a default-argument thunk is
        // nonisolated and so cannot construct the @MainActor transport. Same reason
        // `CameraService.init` resolves `backend ?? MetaCameraBackend()` inside its body.
        let transport = transport ?? RokidAudioTransport()
        self.transport = transport
        self.transport.onAudioFrame = { [weak self] data in
            self?.onAudioFrame?(data)
        }
        self.transport.onDisconnect = { [weak self] error in
            guard let self else { return }
            self.onError?(error ?? RokidMicrophoneError.notConnected)
        }
    }

    func startCapture() async throws {
        guard capabilities.streamsWearerAudio else {
            throw RokidMicrophoneError.streamUnavailable
        }
        guard isAvailable else {
            throw RokidMicrophoneError.notPaired
        }
        guard !transport.isConnected else { return }
        do {
            try await transport.connect()
        } catch {
            onError?(error)
            throw error
        }
        guard transport.isConnected else {
            throw RokidMicrophoneError.notConnected
        }
    }

    func stopCapture() async {
        transport.disconnect()
    }

    func shutdown() async {
        await stopCapture()
    }

    func resetAfterError() {}
}

enum RokidMicrophoneError: Error, Equatable, LocalizedError {
    /// No Rokid device has been paired in Settings.
    case notPaired
    /// The transport is not connected.
    case notConnected
    /// The glasses-native stream is not implemented for this backend.
    case streamUnavailable

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return "No Rokid Glasses are paired."
        case .notConnected:
            return "Not connected to Rokid Glasses."
        case .streamUnavailable:
            return "Rokid's microphone stream isn't available yet — the Bluetooth headset route still works."
        }
    }
}
