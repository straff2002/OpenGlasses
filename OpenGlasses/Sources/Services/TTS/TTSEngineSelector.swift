import Foundation

/// One of the three TTS engines OpenGlasses can speak through, in descending quality:
/// cloud ElevenLabs, on-device neural Kokoro, and the built-in AVSpeechSynthesizer.
enum TTSEngine: String, CaseIterable, Equatable {
    /// ElevenLabs cloud TTS — best quality, paid, needs a key + network.
    case elevenLabs
    /// Kokoro on-device neural TTS (sherpa-onnx / ONNX-CPU) — free, offline, runs backgrounded.
    case kokoro
    /// iOS `AVSpeechSynthesizer` — robotic but always available (no key, no model, no network).
    case system
}

/// The user's TTS-engine preference (Additional Capabilities #1). Persisted as a raw string in
/// `Config.ttsEnginePreference`; drives `TTSEngineSelector`.
enum TTSEnginePreference: String, CaseIterable, Identifiable, Codable {
    /// Best available given what's configured — the historical behaviour, plus Kokoro inserted
    /// between ElevenLabs and the system voice.
    case auto
    /// Prefer the ElevenLabs cloud voice (graceful fallback to Kokoro then system).
    case elevenLabs
    /// Prefer the on-device Kokoro voice; never silently fall back to the *paid* cloud.
    case kokoro
    /// Always use the built-in iOS voice.
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .elevenLabs: return "Cloud (ElevenLabs)"
        case .kokoro: return "On-Device (Kokoro)"
        case .system: return "System (iOS)"
        }
    }

    /// One-line description for the Settings picker footer.
    var detail: String {
        switch self {
        case .auto: return "Use the best voice available: ElevenLabs if configured, then on-device Kokoro, then the iOS voice."
        case .elevenLabs: return "Prefer ElevenLabs cloud voices. Falls back to on-device or the iOS voice when unavailable."
        case .kokoro: return "Prefer the offline, free on-device neural voice. Falls back to the iOS voice — never the paid cloud."
        case .system: return "Always use the built-in iOS voice."
        }
    }
}

/// Pure engine-selection policy for `TextToSpeechService` (Additional Capabilities #1 — the headline
/// Kokoro tier). Given what's *available* (ElevenLabs key + online, Kokoro model present), the user's
/// preference, and the utterance urgency, it produces the ordered fallback chain the service walks
/// (`ElevenLabs → Kokoro → AVSpeech`), trying each engine until one succeeds.
///
/// No `TextToSpeechService` / SDK / audio state is touched here — it's a value computation, so the
/// whole cascade is unit-testable headlessly (no hardware, no binary).
enum TTSEngineSelector {

    /// What each engine can actually do *right now*. The caller folds the live signals
    /// (key presence, reachability, quota, model files on disk, whether the Kokoro binary is even
    /// compiled in) into these two booleans; the policy stays pure.
    struct Availability: Equatable {
        /// ElevenLabs key present **and** online **and** not quota-exhausted.
        var elevenLabsReady: Bool
        /// Kokoro model files present **and** the engine is compiled into this build.
        var kokoroReady: Bool

        init(elevenLabsReady: Bool, kokoroReady: Bool) {
            self.elevenLabsReady = elevenLabsReady
            self.kokoroReady = kokoroReady
        }
    }

    /// The ordered list of engines to try, best-first. The first element is the chosen engine;
    /// the rest are the fallback order. `.system` is always the final element — it needs no key,
    /// no model, and no network, so it's the guaranteed terminal fallback that can never fail to
    /// be *available* (though playback can still error, in which case the chain is exhausted).
    static func chain(preference: TTSEnginePreference,
                      availability: Availability,
                      urgency: TextToSpeechService.SpeechUrgency = .low) -> [TTSEngine] {
        // 1. Preferred order from the user's choice.
        var order: [TTSEngine]
        switch preference {
        case .auto, .elevenLabs:
            order = [.elevenLabs, .kokoro, .system]
        case .kokoro:
            // Explicit on-device choice: never silently fall back to the *paid* cloud.
            order = [.kokoro, .system]
        case .system:
            order = [.system]
        }

        // 2. Urgency adjustment. A high-urgency utterance (e.g. a Navigation Assist hazard alert)
        //    shouldn't wait on a network round-trip, so promote a *ready* on-device neural engine
        //    (Kokoro) ahead of the network engine (ElevenLabs). We never downgrade to the robotic
        //    system voice purely for speed — quality still matters for an alert — so System is left
        //    where it is.
        if urgency == .high, availability.kokoroReady,
           let elevenIdx = order.firstIndex(of: .elevenLabs),
           let kokoroIdx = order.firstIndex(of: .kokoro),
           kokoroIdx > elevenIdx {
            order.remove(at: kokoroIdx)
            order.insert(.kokoro, at: elevenIdx)
        }

        // 3. Drop engines that aren't available; keep `.system` as the guaranteed terminal.
        var result = order.filter { engine in
            switch engine {
            case .elevenLabs: return availability.elevenLabsReady
            case .kokoro: return availability.kokoroReady
            case .system: return true
            }
        }
        if !result.contains(.system) { result.append(.system) }
        return result
    }

    /// The single engine to speak through — the head of `chain(...)`. Always non-nil because the
    /// chain always terminates in `.system`.
    static func select(preference: TTSEnginePreference,
                       availability: Availability,
                       urgency: TextToSpeechService.SpeechUrgency = .low) -> TTSEngine {
        chain(preference: preference, availability: availability, urgency: urgency).first ?? .system
    }
}
