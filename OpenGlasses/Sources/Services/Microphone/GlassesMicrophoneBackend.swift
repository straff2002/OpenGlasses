import Foundation

/// What a glasses microphone can do, declared honestly.
///
/// The display and camera seams answer "can we render?" and "can we see?". This one is narrower,
/// because the app already has a working voice loop for *any* glasses that pair as a Bluetooth
/// headset (`GlassesTier.audioOnly`): `AVAudioSession` puts the glasses' HFP input in the route and
/// wake word, transcription, LLM, tools and TTS all work with no protocol code at all.
///
/// What does not exist yet is a glasses-native stream — the device sending its own microphone to the
/// phone as framed audio over the vendor protocol. Meta's capture protocol models it
/// (`CaptureNotification.microphoneAudio`, OPUS / 16 kHz / mono / ~20 ms on opcode `0x59`); Rokid's
/// equivalent is the `ARTC` / `Ai` audio path inside CXRService. Neither decoding nor consumption
/// exists in this app today, so a backend that claims `streamsWearerAudio` without one is lying.
struct MicrophoneCapabilities: Sendable, Equatable {
    /// The glasses send their own microphone to the phone over the vendor protocol.
    let streamsWearerAudio: Bool
    /// Capture runs continuously while started (not one utterance per start).
    let liveStream: Bool
    /// The glasses' microphone is selectable as a Bluetooth headset input with no protocol work.
    ///
    /// This is the path the app actually uses today (`MicRoutePolicy.bluetoothMicPorts`).
    let routesViaBluetoothHFP: Bool
    /// Encoding of framed audio, meaningful when `liveStream` is true.
    let encoding: MicrophoneEncoding

    enum MicrophoneEncoding: String, Sendable, Equatable {
        /// Opus, 16 kHz mono, roughly 20 ms per frame — the shape both vendor protocols document.
        case opus16kMono
        /// Raw signed 16-bit PCM, 16 kHz mono.
        case pcm16kMono
    }

    /// No native stream, but the HFP route still carries the whole voice loop.
    static let bluetoothHeadsetOnly = MicrophoneCapabilities(
        streamsWearerAudio: false,
        liveStream: false,
        routesViaBluetoothHFP: true,
        encoding: .opus16kMono
    )

    /// No microphone at all: no glasses, or a backend that cannot start.
    static let unavailable = MicrophoneCapabilities(
        streamsWearerAudio: false,
        liveStream: false,
        routesViaBluetoothHFP: false,
        encoding: .opus16kMono
    )
}

/// A glasses microphone that can stream its own audio to the phone.
///
/// Deliberately frame-oriented and small: a backend hands over encoded frames and says what they
/// are; decoding and routing stay with the capture pipeline (`CaptureAudioRouter` and its
/// `BroadcastAudioProviding` consumers). `onAudioFrame` carries the bytes the vendor protocol puts
/// on the wire, never resampled or re-encoded here — so a future decode step has one place to read
/// the format from: `capabilities.encoding`.
@MainActor
protocol GlassesMicrophoneBackend: AnyObject {
    var capabilities: MicrophoneCapabilities { get }
    /// Whether capture could start right now (paired, transport reachable).
    var isAvailable: Bool { get }
    /// Encoded frames, in `capabilities.encoding`.
    var onAudioFrame: ((Data) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func startCapture() async throws
    func stopCapture() async
    func shutdown() async
    func resetAfterError()
}
