import Foundation

/// Plan BY P2 — translated-caption settings and the cloud-tier gate.
extension Config {

    /// Master toggle for translated captions. Off by default — when off, ambient captions
    /// transcribe exactly as before (no translation path is touched).
    static var translationCaptionsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "translationCaptionsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "translationCaptionsEnabled") }
    }

    /// BCP-47 code the captions render in.
    static var translationTargetLanguage: String {
        get { UserDefaults.standard.string(forKey: "translationTargetLanguage") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "translationTargetLanguage") }
    }

    /// Show the source-language transcript as a secondary ribbon under each translated caption.
    static var translationShowOriginal: Bool {
        get { UserDefaults.standard.bool(forKey: "translationShowOriginal") }
        set { UserDefaults.standard.set(newValue, forKey: "translationShowOriginal") }
    }

    /// Cloud-tier gate — mirrors `isDiarizationConfigured`: explicit opt-in + a usable key +
    /// **not** HIPAA. Checked at session start AND on every audio buffer (`GeminiTranslationProvider`),
    /// so a mid-session HIPAA flip stops audio egress immediately.
    static var isTranslationCloudConfigured: Bool {
        translationCaptionsEnabled && isGeminiLiveConfigured && !hipaaMode
    }
}

/// Curated language-pair scope for the v1 UI (BY open decision: curated beats free-pick — the
/// picker stays scannable and every entry is a language the cloud tier translates well).
enum TranslationLanguages {
    /// `(BCP-47 code, English display name)`, alphabetical by name.
    static let curated: [(code: String, name: String)] = [
        ("zh", "Chinese"),
        ("en", "English"),
        ("fr", "French"),
        ("de", "German"),
        ("hi", "Hindi"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("pt", "Portuguese"),
        ("es", "Spanish"),
        ("th", "Thai"),
        ("vi", "Vietnamese"),
    ]

    static func displayName(for code: String) -> String {
        curated.first(where: { $0.code == code })?.name
            ?? Locale(identifier: "en").localizedString(forIdentifier: code)
            ?? code
    }
}
