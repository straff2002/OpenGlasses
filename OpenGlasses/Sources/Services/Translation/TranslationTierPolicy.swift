import Foundation

/// Which translation backend a session should use.
enum TranslationTier: Equatable {
    /// Unified STT+translation stream over the Gemini Live wire.
    case cloud
    /// SenseVoice → Apple Translation, zero cloud egress (P3).
    case onDevice
    /// No usable backend — the caption path falls through to plain transcription.
    case unavailable(reason: String)
}

/// Pure tier selection (BY): offline/HIPAA → on-device; else cloud. Surfaced honestly in the UI —
/// the reason string is user-facing copy, never a silent fallback.
enum TranslationTierPolicy {

    static func tier(hipaa: Bool, offline: Bool, cloudConfigured: Bool, onDeviceAvailable: Bool) -> TranslationTier {
        if hipaa {
            return onDeviceAvailable
                ? .onDevice
                : .unavailable(reason: "Cloud translation is disabled in HIPAA mode, and the on-device translator is not installed.")
        }
        if offline {
            return onDeviceAvailable
                ? .onDevice
                : .unavailable(reason: "Offline, and the on-device translator is not installed.")
        }
        if cloudConfigured { return .cloud }
        if onDeviceAvailable { return .onDevice }
        return .unavailable(reason: "Translation is not configured.")
    }
}
