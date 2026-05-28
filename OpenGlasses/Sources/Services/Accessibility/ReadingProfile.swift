import Foundation

/// User preferences for the Reading Accessibility feature (A1). UserDefaults-backed so they persist
/// and can default tool calls when the LLM doesn't specify a level or language.
enum ReadingProfile {

    /// Reading-simplification level, 1 (simplest) to 5 (professional).
    enum Level: Int, CaseIterable {
        case child = 1      // ages 6–10
        case youth = 2      // ages 11–14
        case adult = 3      // general adult
        case expert = 4     // domain-literate
        case professional = 5

        var audienceDescription: String {
            switch self {
            case .child: return "a child aged 6–10"
            case .youth: return "a young person aged 11–14"
            case .adult: return "a general adult reader"
            case .expert: return "a knowledgeable adult"
            case .professional: return "a professional in the field"
            }
        }
    }

    private static let levelKey = "accessibilityReadingLevel"
    private static let languageKey = "accessibilityReadingLanguage"

    /// Preferred reading level (default: adult).
    static var level: Level {
        let raw = UserDefaults.standard.object(forKey: levelKey) as? Int ?? Level.adult.rawValue
        return Level(rawValue: raw) ?? .adult
    }

    static func setLevel(_ level: Level) {
        UserDefaults.standard.set(level.rawValue, forKey: levelKey)
    }

    /// Preferred translation target language code (e.g. "es"). Defaults to the device language.
    static var preferredLanguage: String {
        UserDefaults.standard.string(forKey: languageKey)
            ?? Locale.current.language.languageCode?.identifier
            ?? "en"
    }

    static func setPreferredLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: languageKey)
    }

    /// Human-readable name for a language code, for prompts ("es" → "Spanish").
    static func languageName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
