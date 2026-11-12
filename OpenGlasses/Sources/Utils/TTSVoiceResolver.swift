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

    // MARK: - A voice for the reply's language

    /// The language a reply was detected as, and how sure the detection was (0…1).
    struct DetectedLanguage: Equatable {
        /// BCP 47, as the recognizer names it ("es", "zh-Hans").
        let code: String
        let confidence: Double
    }

    /// How sure the detection must be before the voice changes. The dominant hypothesis has to
    /// clear it: an English sentence quoting one Spanish word stays well under, a Spanish sentence
    /// sits near 1. Below it the chosen voice reads the reply, as it always did.
    static let switchConfidence = 0.8
    /// Letters a reply needs before its language is trusted: a name, a number or "OK" reads the
    /// same in any voice, and the recognizer guesses wildly on them. Han, kana and Hangul carry
    /// more per character, so fewer of them are enough.
    static let minimumSwitchLetters = 12
    static let minimumLogographicSwitchLetters = 4

    /// Letters in `text`, and whether it is written in a logographic or syllabic script. Pure.
    static func letterCount(of text: String) -> (letters: Int, logographic: Bool) {
        var letters = 0
        var logographic = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: logographic += 1
            default: break
            }
        }
        return (letters, logographic * 2 > letters)
    }

    /// Whether a reply is worth looking for another voice for: long enough, detected with
    /// confidence, and in a language the chosen voice does not speak. Pure; checked before the
    /// installed voices are listed, so most replies cost one recognizer pass and nothing more.
    static func wantsLanguageSwitch(chosenLanguage: String?, detected: DetectedLanguage?,
                                    letters: Int, logographic: Bool) -> Bool {
        guard let detected, detected.confidence >= switchConfidence else { return false }
        guard letters >= (logographic ? minimumLogographicSwitchLetters : minimumSwitchLetters) else { return false }
        if let chosenLanguage, matchesLanguage(chosenLanguage, detected.code) { return false }
        return true
    }

    /// The voice that reads one reply. The chosen voice (the saved one, or `resolve`'s pick) is
    /// kept unless the reply is confidently in a language it does not speak and a voice for that
    /// language is installed; then the best of those: a region the user has among their device
    /// languages first, then the chosen voice's own region, then quality, as `resolve` ranks.
    /// Pure.
    static func voiceForReply(chosen: Voice?, detected: DetectedLanguage?, letters: Int, logographic: Bool,
                              preferredLanguages: [String], voices: [Voice]) -> Voice? {
        guard wantsLanguageSwitch(chosenLanguage: chosen?.language, detected: detected,
                                  letters: letters, logographic: logographic),
              let detected else { return chosen }
        let candidates = voices.filter { matchesLanguage($0.language, detected.code) }
        guard !candidates.isEmpty else { return chosen }
        let preferred = preferredLanguages.map(canonical)
        let chosenRegion = chosen.flatMap { Locale.Language(identifier: $0.language).region?.identifier }
        func rank(_ voice: Voice) -> (Int, Int) {
            let preferredIndex = preferred.firstIndex(of: canonical(voice.language)) ?? preferred.count
            let region = Locale.Language(identifier: voice.language).region?.identifier
            return (preferredIndex, chosenRegion != nil && region == chosenRegion ? 0 : 1)
        }
        return candidates.sorted { lhs, rhs in
            let (l, r) = (rank(lhs), rank(rhs))
            if l != r { return l < r }
            return qualityOrder(lhs, rhs)
        }.first
    }

    // MARK: - Pointing at the better system voices

    /// `AVSpeechSynthesisVoiceQuality.premium.rawValue`; `.enhanced` is 2 and the compact voice
    /// every language ships with is 1. Kept as a number so the policy stays free of AVFoundation.
    static let premiumQuality = 3
    static let enhancedQuality = 2

    /// The case for downloading a better system voice, when there is one to make.
    ///
    /// iOS ships every language with a compact voice and keeps the Enhanced and Premium ones as
    /// downloads under Accessibility › Read & Speak › Voices. A tester on an iPhone 17 Pro
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
