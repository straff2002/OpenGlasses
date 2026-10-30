import Foundation

/// One of the TTS engines OpenGlasses can speak through: four cloud voices, the on-device neural
/// Kokoro, and the built-in AVSpeechSynthesizer.
enum TTSEngine: String, CaseIterable, Equatable {
    /// ElevenLabs cloud TTS — best quality, paid, needs a key + network.
    case elevenLabs
    /// OpenAI's speech endpoint — paid API credit on the OpenAI key the LLM already uses.
    case openAI
    /// xAI's speech endpoint — the saved xAI key, or the connected xAI account.
    case xai
    /// Google's Gemini speech model — the key saved with the Gemini model, spending its quota
    /// (Plan JZ).
    case gemini
    /// Kokoro on-device neural TTS (sherpa-onnx / ONNX-CPU) — free, offline, runs backgrounded.
    case kokoro
    /// iOS `AVSpeechSynthesizer` — robotic but always available (no key, no model, no network).
    case system

    /// The cloud voices, in the order `.auto` tries them. Gemini comes last (Plan JZ): each is
    /// tried only with its key saved, so a Gemini key turns the Gemini voice on.
    static let cloudVoices: [TTSEngine] = [.elevenLabs, .openAI, .xai, .gemini]

    /// Whether this engine sends the reply text off the phone.
    var isCloud: Bool { Self.cloudVoices.contains(self) }

    /// The vendor a cloud voice is named by in what the wearer hears and reads; nil on the phone.
    var vendorName: String? {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        case .xai: return "xAI"
        case .gemini: return "Gemini"
        case .kokoro, .system: return nil
        }
    }

    /// The network route a cloud voice's synthesis request travels on; nil on the phone.
    var speechRoute: NetworkRoute? {
        switch self {
        case .elevenLabs: return .elevenLabsSpeechSynthesis
        case .openAI: return .openAISpeechSynthesis
        case .xai: return .xaiSpeechSynthesis
        case .gemini: return .geminiSpeechSynthesis
        case .kokoro, .system: return nil
        }
    }
}

/// The user's TTS-engine preference (Additional Capabilities #1). Persisted as a raw string in
/// `Config.ttsEnginePreference`; drives `TTSEngineSelector`.
enum TTSEnginePreference: String, CaseIterable, Identifiable, Codable {
    /// Best available given what's configured — the historical behaviour, plus Kokoro inserted
    /// between the cloud voices and the system voice.
    case auto
    /// Prefer the ElevenLabs cloud voice (graceful fallback to Kokoro then system).
    case elevenLabs
    /// Prefer the OpenAI cloud voice (graceful fallback to Kokoro then system).
    case openAI
    /// Prefer the xAI cloud voice (graceful fallback to Kokoro then system).
    case xai
    /// Prefer the Gemini cloud voice (graceful fallback to Kokoro then system).
    case gemini
    /// Prefer the on-device Kokoro voice; never silently fall back to the *paid* cloud.
    case kokoro
    /// Always use the built-in iOS voice.
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .elevenLabs: return String(localized: "Cloud (ElevenLabs)")
        case .openAI: return String(localized: "Cloud (OpenAI)")
        case .xai: return String(localized: "Cloud (xAI)")
        case .gemini: return String(localized: "Cloud (Gemini)")
        case .kokoro: return String(localized: "On-Device (Kokoro)")
        case .system: return String(localized: "System (iOS)")
        }
    }

    /// One-line description for the Settings picker footer.
    var detail: String { detail(now: Date()) }

    func detail(now: Date) -> String {
        switch self {
        case .auto: return String(localized: "Use the best voice available: a cloud voice if one is set up (ElevenLabs, then OpenAI, then xAI, then Gemini), then on-device Kokoro, then the iOS voice.")
        case .elevenLabs: return String(localized: "Prefer ElevenLabs cloud voices. Falls back to on-device or the iOS voice when unavailable.")
        case .openAI:
            let detail = String(localized: "Prefer the OpenAI cloud voice, paid from your OpenAI API credit. Falls back to on-device or the iOS voice when unavailable — never another paid cloud.")
            return OpenAIVoiceRetirement.pickerNote(now: now).map { "\(detail) \($0)" } ?? detail
        case .xai: return String(localized: "Prefer the xAI cloud voice, using your xAI key or sign-in. Falls back to on-device or the iOS voice when unavailable — never another paid cloud.")
        case .gemini: return String(localized: "Prefer the Gemini cloud voice, using the API key saved with your Gemini model. Spoken replies use that key's quota, separately from chat. Falls back to on-device or the iOS voice when unavailable — never another paid cloud.")
        case .kokoro: return String(localized: "Prefer the offline, free on-device neural voice. Falls back to the iOS voice — never the paid cloud.")
        case .system: return String(localized: "Always use the built-in iOS voice.")
        }
    }

    /// The cloud voice this preference names, if it names one.
    var cloudEngine: TTSEngine? {
        switch self {
        case .elevenLabs: return .elevenLabs
        case .openAI: return .openAI
        case .xai: return .xai
        case .gemini: return .gemini
        case .auto, .kokoro, .system: return nil
        }
    }
}

/// Pure engine-selection policy for `TextToSpeechService` (Additional Capabilities #1 — the headline
/// Kokoro tier). Given what's *available* (each cloud voice's credential + online, Kokoro model
/// present), the user's preference, and the utterance urgency, it produces the ordered fallback chain
/// the service walks (`ElevenLabs → OpenAI → xAI → Gemini → Kokoro → AVSpeech` at most), trying each engine
/// until one succeeds.
///
/// No `TextToSpeechService` / SDK / audio state is touched here — it's a value computation, so the
/// whole cascade is unit-testable headlessly (no hardware, no binary).
enum TTSEngineSelector {

    /// What each engine can actually do *right now*. The caller folds the live signals
    /// (key presence, reachability, quota, model files on disk, whether the Kokoro binary is even
    /// compiled in) into these booleans; the policy stays pure.
    struct Availability: Equatable {
        /// ElevenLabs key present **and** online **and** not quota-exhausted.
        var elevenLabsReady: Bool
        /// Kokoro model files present **and** the engine is compiled into this build.
        var kokoroReady: Bool
        /// OpenAI API key present **and** online **and** not quota-exhausted.
        var openAIReady: Bool
        /// xAI key or signed-in account present **and** online **and** not quota-exhausted.
        var xaiReady: Bool
        /// A Gemini key on Google's own host present **and** online **and** not quota-exhausted.
        var geminiReady: Bool

        init(elevenLabsReady: Bool, kokoroReady: Bool,
             openAIReady: Bool = false, xaiReady: Bool = false, geminiReady: Bool = false) {
            self.elevenLabsReady = elevenLabsReady
            self.kokoroReady = kokoroReady
            self.openAIReady = openAIReady
            self.xaiReady = xaiReady
            self.geminiReady = geminiReady
        }

        func isReady(_ engine: TTSEngine) -> Bool {
            switch engine {
            case .elevenLabs: return elevenLabsReady
            case .openAI: return openAIReady
            case .xai: return xaiReady
            case .gemini: return geminiReady
            case .kokoro: return kokoroReady
            case .system: return true
            }
        }
    }

    /// Whether a cloud voice may be tried for one utterance: a credential on file, not latched off
    /// (`quotaExhausted` covers out of credit and a withdrawn model), online, not an utterance the app promised to keep on the phone, and a route the
    /// medical local-only rule lets out. One rule for every cloud voice, so they cannot drift.
    static func cloudVoiceReady(_ engine: TTSEngine, hasCredential: Bool, quotaExhausted: Bool,
                                onDeviceOnly: Bool, online: Bool,
                                medicalMode: MedicalEgressGuard.Mode) -> Bool {
        guard let route = engine.speechRoute else { return false }
        return hasCredential
            && !quotaExhausted
            && !onDeviceOnly
            && online
            && MedicalEgressGuard.decide(route, mode: medicalMode).isAllowed
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
        case .auto:
            order = TTSEngine.cloudVoices + [.kokoro, .system]
        case .elevenLabs, .openAI, .xai, .gemini:
            // A chosen cloud voice falls back to the phone, never to a different paid cloud: the
            // wearer picked whose account pays for the voice.
            order = [preference.cloudEngine ?? .elevenLabs, .kokoro, .system]
        case .kokoro:
            // Explicit on-device choice: never silently fall back to the *paid* cloud.
            order = [.kokoro, .system]
        case .system:
            order = [.system]
        }

        // 2. Urgency adjustment. A high-urgency utterance (e.g. a Navigation Assist hazard alert)
        //    shouldn't wait on a network round-trip, so promote a *ready* on-device neural engine
        //    (Kokoro) ahead of every network engine. We never downgrade to the robotic system voice
        //    purely for speed — quality still matters for an alert — so System is left where it is.
        if urgency == .high, availability.kokoroReady,
           let firstCloudIdx = order.firstIndex(where: \.isCloud),
           let kokoroIdx = order.firstIndex(of: .kokoro),
           kokoroIdx > firstCloudIdx {
            order.remove(at: kokoroIdx)
            order.insert(.kokoro, at: firstCloudIdx)
        }

        // 3. Drop engines that aren't available; keep `.system` as the guaranteed terminal.
        var result = order.filter { availability.isReady($0) }
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
