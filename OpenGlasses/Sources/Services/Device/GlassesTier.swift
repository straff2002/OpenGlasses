import Foundation

/// Plan CQ P0 — what class of device is connected, from the app's point of view.
///
/// "Which glasses does OpenGlasses work with?" had one answer for most of this project's life,
/// and it was a product name. It isn't one any more: the microphone path is plain
/// `AVAudioSession` routing, so **any** glasses that pair as a Bluetooth headset already carry
/// the entire voice loop — wake word, transcription, LLM, tools, TTS — with no protocol work at
/// all. What varies between devices is the camera and the display, not the voice.
///
/// So the honest unit is a tier, and the tier is what Settings shows.
enum GlassesTier: String, Sendable, Equatable, CaseIterable {
    /// Paired as a Bluetooth headset. The voice loop works; there is no camera or HUD for us.
    case audioOnly
    /// A HUD we can render to (Plan AH's `GlassesDisplayBackend`), but no camera.
    case displayOnly
    /// A camera backend we can drive. What it can *do* is `CameraCapabilities`, not this.
    case camera

    var label: String {
        switch self {
        case .audioOnly: return "Audio only"
        case .displayOnly: return "Display"
        case .camera: return "Camera"
        }
    }

    /// One line for the Settings device row — what the user gets, not what they don't.
    var summary: String {
        switch self {
        case .audioOnly:
            return "Voice, wake word and spoken replies. Camera features use the iPhone camera."
        case .displayOnly:
            return "Voice, wake word, spoken replies and the in-lens HUD. No camera."
        case .camera:
            return "Voice, wake word, spoken replies and the glasses camera."
        }
    }
}

/// Pure tier resolution. No SDK, no audio session, no I/O — the caller passes in what it
/// observed and gets back the tier.
enum GlassesTierPolicy {

    /// Resolve the tier of whatever is currently connected.
    ///
    /// - Parameters:
    ///   - cameraCapabilities: the active camera backend's capabilities, or nil when no camera
    ///     backend is usable right now (unregistered SDK, glasses offline, simulator).
    ///   - displayBackendActive: whether a `GlassesDisplayBackend` is connected and rendering.
    ///   - audioPortNames: names of the currently available Bluetooth audio input ports.
    /// - Returns: the tier, or nil when nothing glasses-like is connected at all — which is a
    ///   different statement from "connected but limited" and must not be collapsed into one.
    ///
    /// Ordering is most-capable-wins, because a device can legitimately answer to more than one:
    /// camera glasses are also audio devices, and Meta's Display glasses are all three. The tier
    /// names the best thing available, and `CameraCapabilities` carries the detail.
    static func resolve(
        cameraCapabilities: CameraCapabilities?,
        displayBackendActive: Bool,
        audioPortNames: [String]
    ) -> GlassesTier? {
        if let capabilities = cameraCapabilities,
           capabilities.stillCapture || capabilities.liveFrames {
            return .camera
        }
        if displayBackendActive { return .displayOnly }
        if audioPortNames.contains(where: { MicRoutePolicy.looksLikeGlasses(portName: $0) }) {
            return .audioOnly
        }
        return nil
    }
}
