import Foundation

/// Pure selection policy, independent of the voices installed on the test device.
enum TTSVoiceResolver {
    struct Voice: Equatable {
        let identifier: String
        let language: String
        let quality: Int
        let name: String
    }

    static func resolve(savedIdentifier: String, preferredLanguages: [String], voices: [Voice]) -> Voice? {
        if let saved = voices.first(where: { $0.identifier == savedIdentifier }) { return saved }
        for language in preferredLanguages + ["en-US"] {
            let exact = voices.filter { canonical($0.language) == canonical(language) }
            if let best = exact.sorted(by: qualityOrder).first { return best }
            let compatible = voices.filter { matchesLanguage($0.language, language) }
            if let best = compatible.sorted(by: qualityOrder).first { return best }
        }
        return nil
    }

    /// Include all qualities in preferred languages, English, and the saved voice.
    static func available(savedIdentifier: String, preferredLanguages: [String], voices: [Voice]) -> [Voice] {
        voices.filter { voice in
            voice.identifier == savedIdentifier || (preferredLanguages + ["en-US"]).contains {
                matchesLanguage(voice.language, $0)
            }
        }.sorted(by: qualityOrder)
    }

    // MARK: - Pointing at the better system voices

    /// `AVSpeechSynthesisVoiceQuality.premium.rawValue`; `.enhanced` is 2 and the compact voice
    /// every language ships with is 1. Kept as a number so the policy stays free of AVFoundation.
    static let premiumQuality = 3
    static let enhancedQuality = 2

    /// The case for downloading a better system voice, when there is one to make.
    ///
    /// iOS ships every language with a compact voice and keeps the Enhanced and Premium ones as
    /// downloads under Accessibility › Spoken Content › Voices. A tester on an iPhone 17 Pro
    /// reported the on-device voice as "too slow" when the fast, natural answer was one download
    /// away; nothing in the app said so. This names the language the app would speak in and how
    /// good the voice it would use is, so the settings screen can say exactly what to fetch.
    struct QualityAdvice: Equatable {
        /// Language of the voice the app would use (a BCP 47 identifier such as "ko-KR").
        let language: String
        /// Quality of that voice, `0` when the app has no voice for the language at all.
        let installedQuality: Int

        var isCompactOnly: Bool { installedQuality < TTSVoiceResolver.enhancedQuality }
    }

    /// `nil` when the voice the app would speak with is already Premium (or the wearer pinned a
    /// voice the system no longer lists — nothing to say about a voice we cannot see).
    static func qualityAdvice(savedIdentifier: String, preferredLanguages: [String],
                              voices: [Voice]) -> QualityAdvice? {
        let chosen = resolve(savedIdentifier: savedIdentifier, preferredLanguages: preferredLanguages,
                             voices: voices)
        if let chosen, chosen.quality >= premiumQuality { return nil }
        let language = chosen?.language ?? preferredLanguages.first ?? "en-US"
        return QualityAdvice(language: language, installedQuality: chosen?.quality ?? 0)
    }

    private static func matchesLanguage(_ lhs: String, _ rhs: String) -> Bool {
        let left = Locale.Language(identifier: lhs)
        let right = Locale.Language(identifier: rhs)
        guard let code = left.languageCode, code == right.languageCode else { return false }
        // Foundation infers scripts for regional locales too (zh-TW → Hant), so
        // a region fallback never substitutes Simplified for Traditional Chinese.
        if let leftScript = left.script, let rightScript = right.script {
            return leftScript == rightScript
        }
        return true
    }

    private static func canonical(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func qualityOrder(_ lhs: Voice, _ rhs: Voice) -> Bool {
        if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.identifier < rhs.identifier
    }
}
