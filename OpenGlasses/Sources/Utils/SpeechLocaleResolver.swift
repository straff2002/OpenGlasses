import Foundation
import Speech

/// Resolves which `SFSpeechRecognizer` locale the speech features use — wake word,
/// transcription, ambient captions, memory rewind, teleprompter. Previously all of them
/// hardcoded en-US, so non-English wake phrases and dictation quietly under-performed.
///
/// `"auto"` (the default) follows the device's preferred languages, constrained to what
/// `SFSpeechRecognizer` actually supports on this OS; an explicit identifier pins it (with
/// same-language region fallback: fr-CA → fr-FR when only fr-FR is supported, and the language's
/// home region when several are — en-MX → en-US, never the first in the alphabet). en-US is
/// the last-resort fallback — exactly the old behavior for English-device users.
enum SpeechLocaleResolver {

    static let automatic = "auto"

    /// Pure resolution: preference + device languages + supported identifiers → identifier.
    /// Matching is case- and separator-insensitive; the returned value is always one of
    /// `supported` (or "en-US" when nothing matches).
    static func resolve(preference: String, deviceLanguages: [String], supported: [String]) -> String {
        // lowercased-canonical → original supported identifier (first wins per key)
        var exact: [String: String] = [:]
        var byLanguage: [String: [String]] = [:]
        for identifier in supported.sorted() {
            let key = canonical(identifier)
            if exact[key] == nil { exact[key] = identifier }
            byLanguage[languageCode(of: identifier), default: []].append(identifier)
        }

        func bestMatch(_ candidate: String) -> String? {
            if let hit = exact[canonical(candidate)] { return hit }
            let language = languageCode(of: candidate)
            guard let sameLanguage = byLanguage[language] else { return nil }
            // The language's own home region, not whichever sorts first. An English phone in a
            // region Apple has no English recogniser for (en-MX, device-reported 2026-10-05) was
            // given en-AE — first in the alphabet — and with it no on-device recognition.
            let home = likelyRegion(of: language)
            return sameLanguage.first { region(of: $0) == home } ?? sameLanguage.first
        }

        if preference != automatic, let match = bestMatch(preference) { return match }
        for language in deviceLanguages {
            if let match = bestMatch(language) { return match }
        }
        return "en-US"
    }

    /// The live resolution the speech services use when creating a recognizer.
    static var current: Locale {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        let identifier = resolve(
            preference: Config.speechRecognitionLocale,
            deviceLanguages: Locale.preferredLanguages,
            supported: supported
        )
        return Locale(identifier: identifier)
    }

    // MARK: - Private

    private static func canonical(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func languageCode(of identifier: String) -> String {
        canonical(identifier).components(separatedBy: "-").first ?? identifier
    }

    private static func region(of identifier: String) -> String? {
        Locale.Language(identifier: identifier).region?.identifier
    }

    /// Where a language is most spoken, by the system's own likely-subtags table: en → US,
    /// pt → BR, fr → FR, zh → CN.
    private static func likelyRegion(of language: String) -> String? {
        region(of: Locale.Language(identifier: language).maximalIdentifier)
    }
}
