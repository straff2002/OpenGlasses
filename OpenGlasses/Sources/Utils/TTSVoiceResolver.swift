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
