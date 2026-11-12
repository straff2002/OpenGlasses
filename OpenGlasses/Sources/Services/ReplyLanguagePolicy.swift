import Foundation

/// Which language a spoken reply is in, given the voice that will say it.
///
/// Answering a Spanish question in Spanish is right only when the voice can say Spanish: through a
/// voice that speaks only English the answer comes out as English sounds over Spanish words. So the
/// prompt's language rule follows the voice. A voice that speaks any language gets "answer in the
/// language the user spoke"; one with a short list answers in a language on its list, else in the
/// app's language (or the voice's own first one), quoting the user's words.
///
/// Pure apart from `directModeVoice()`, which reads the voice *settings* only — never the network or
/// a quota latch — so the clause, which sits in the cacheable head, moves only when a setting does.
enum ReplyLanguagePolicy {

    /// What says the reply.
    enum Voice: Equatable {
        /// A live session's own model voice (Gemini Live, OpenAI Realtime): multilingual.
        case liveModel
        /// One of the app's speech engines.
        case engine(TTSEngine)
    }

    /// The languages a voice can speak.
    enum Languages: Equatable {
        case any
        /// ISO 639-1 codes, in the order they are named.
        case only([String])
    }

    /// The language rule the prompt carries.
    enum Clause: Equatable {
        /// Answer in the language the user spoke.
        case followUser
        /// Answer in one of `speaks` when the user spoke it, otherwise in `fallback`; codes.
        case limited(speaks: [String], fallback: String)
    }

    /// The languages each voice can speak, as the app drives it.
    /// - The iOS voice: always (decision 2 of the plan). It switches voice per reply to an installed
    ///   one for the reply's language when the reply is confidently in another language
    ///   (`TTSVoiceResolver.voiceForReply`), and iOS ships a voice for every language it supports.
    /// - ElevenLabs: the model the app sends (`TextToSpeechService.elevenLabsModelID`) is
    ///   multilingual; only an English-only model would limit it.
    /// - OpenAI, xAI and Gemini: their speech models read the text in whatever language it is in
    ///   (the xAI request says `"language": "auto"`, the Gemini model detects it).
    /// - Kokoro: the languages of the bundle's lexicons.
    static func languages(of voice: Voice,
                          elevenLabsModel: String = TextToSpeechService.elevenLabsModelID,
                          kokoroLanguages: [String] = KokoroModelBundle.active.spokenLanguages) -> Languages {
        switch voice {
        case .liveModel:
            return .any
        case .engine(let engine):
            switch engine {
            case .system, .openAI, .xai, .gemini:
                return .any
            case .elevenLabs:
                let model = elevenLabsModel.lowercased()
                return model.hasPrefix("eleven_monolingual") || model.contains("english") ? .only(["en"]) : .any
            case .kokoro:
                return kokoroLanguages.isEmpty ? .only(["en"]) : .only(kokoroLanguages)
            }
        }
    }

    /// The clause for a voice and the app's language.
    static func clause(for languages: Languages, appLanguageCode: String) -> Clause {
        switch languages {
        case .any:
            return .followUser
        case .only(let codes):
            let fallback = codes.contains(appLanguageCode) ? appLanguageCode : (codes.first ?? "en")
            return .limited(speaks: codes, fallback: fallback)
        }
    }

    static func clause(for voice: Voice, appLanguageCode: String = Config.preferredLanguageCode) -> Clause {
        clause(for: languages(of: voice), appLanguageCode: appLanguageCode)
    }

    /// The engine expected to speak a Direct-mode reply, from the settings alone: a chosen voice
    /// is that voice; Auto is the first cloud voice with a credential on file, else Kokoro when its
    /// model is installed, else the iOS voice. Network, consent and quota are left out on purpose —
    /// they change without the setting changing, and the prompt head must not move with them.
    static func expectedEngine(preference: TTSEnginePreference, configuredCloudVoices: [TTSEngine],
                               kokoroReady: Bool) -> TTSEngine {
        switch preference {
        case .elevenLabs, .openAI, .xai, .gemini:
            return preference.cloudEngine ?? .system
        case .kokoro:
            return kokoroReady ? .kokoro : .system
        case .system:
            return .system
        case .auto:
            if let cloud = TTSEngine.cloudVoices.first(where: configuredCloudVoices.contains) { return cloud }
            return kokoroReady ? .kokoro : .system
        }
    }

    /// The voice a Direct-mode or on-device reply is said in, read from the settings.
    @MainActor static func directModeVoice() -> Voice {
        let saved = Config.savedModels
        var configured: [TTSEngine] = []
        if !Config.elevenLabsAPIKey.isEmpty { configured.append(.elevenLabs) }
        if !CloudVoiceCredentials.openAIKey(savedModels: saved, legacyKey: Config.openAIAPIKey).isEmpty {
            configured.append(.openAI)
        }
        if CloudVoiceCredentials.xaiSource(savedModels: saved, accountConnected: XAIOAuthService.shared.isConnected) != .none {
            configured.append(.xai)
        }
        if !CloudVoiceCredentials.geminiKey(savedModels: saved).isEmpty { configured.append(.gemini) }
        let kokoroReady = KokoroTTSEngine.isCompiledIn && KokoroModelStore.shared.isModelPresent
        return .engine(expectedEngine(preference: Config.ttsEnginePreference,
                                      configuredCloudVoices: configured, kokoroReady: kokoroReady))
    }

    // MARK: - The words

    /// "English", "Chinese and English", "English, Chinese and Spanish" — named in English, as the
    /// prompt around it is.
    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    private static func list(_ codes: [String]) -> String {
        let names = codes.map(languageName)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// The line in the full block. Fixed per outcome.
    static func text(_ clause: Clause) -> String {
        switch clause {
        case .followUser:
            return "Answer in the language the user spoke, unless they ask for another."
        case .limited(let speaks, let fallback):
            let fallbackName = languageName(fallback)
            if speaks.count <= 1 {
                return "Your voice speaks only \(fallbackName): answer in \(fallbackName) whatever language the user "
                    + "spoke, quoting their original words where it helps."
            }
            return "Your voice speaks only \(list(speaks)): answer in the language the user spoke when it is one of "
                + "those, otherwise in \(fallbackName), quoting their original words where it helps."
        }
    }

    /// The same rule in a few words, for the on-device short form.
    static func shortText(_ clause: Clause) -> String {
        switch clause {
        case .followUser:
            return "Answer in the language the user spoke."
        case .limited(let speaks, let fallback):
            let fallbackName = languageName(fallback)
            if speaks.count <= 1 { return "Answer in \(fallbackName), quoting other-language words as said." }
            return "Answer in the user's language if it is \(list(speaks).replacingOccurrences(of: " and ", with: " or ")), "
                + "else in \(fallbackName)."
        }
    }
}

extension KokoroModelBundle {
    /// The languages the bundle can speak, read from its lexicon files (`lexicon-us-en.txt` → en),
    /// so the list cannot disagree with what is downloaded.
    var spokenLanguages: [String] {
        var codes: [String] = []
        for file in requiredFiles where file.hasPrefix("lexicon-") && file.hasSuffix(".txt") {
            let stem = file.dropFirst("lexicon-".count).dropLast(".txt".count)
            guard let code = stem.split(separator: "-").last.map(String.init), !codes.contains(code) else { continue }
            codes.append(code)
        }
        return codes
    }
}
