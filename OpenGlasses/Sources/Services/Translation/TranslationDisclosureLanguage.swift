import AVFoundation
import Foundation

/// Plan HP P2 item 10 — the AI-translation disclosure addressed to the *other* person, in their
/// language.
///
/// When a live translation plays from the phone's loudspeaker, the person hearing it is not the
/// wearer and never chose the app. They are told once per launch, in the language they are being
/// translated into, that this is a live AI translation (`AIDisclosureLedger.Surface
/// .translationForListener`); the two-way caption split labels their half "AI translation" the same
/// way. The language is the translation's *target*, resolved against the localizations the string
/// catalog actually ships, and English when it ships none for that language.
///
/// Pure apart from `localized(_:forTarget:bundle:)`, which reads the bundle it is given.
enum TranslationDisclosureLanguage {

    /// The English source of the spoken line. Also the catalog key, and what is said when the
    /// catalog has no translation for the target language.
    static let listenerLineKey = "This is a live AI translation by Avenkin AI."

    /// The English source of the caption label on the other person's half of the split screen.
    static let captionLabelKey = "AI translation"

    /// Which of `available` (a bundle's localizations) speaks to someone whose language is
    /// `target` (a BCP-47 code such as "es", "es-ES" or "pt_BR").
    ///
    /// In order: the exact localization; the bare language ("es" for "es-ES"); a regional variant
    /// of the same language, the first in sorted order so the answer does not depend on the
    /// bundle's ordering ("es-MX" for "es"); otherwise `fallback`. Case and `_`/`-` are ignored,
    /// and the answer is spelled as `available` spells it. "Base" is never a language.
    static func localization(forTarget target: String, available: [String],
                             fallback: String = "en") -> String {
        func normal(_ code: String) -> String {
            code.replacingOccurrences(of: "_", with: "-").lowercased()
        }
        func base(_ code: String) -> String {
            String(normal(code).split(separator: "-", maxSplits: 1).first ?? "")
        }
        let wanted = normal(target.trimmingCharacters(in: .whitespacesAndNewlines))
        let candidates = available.filter { normal($0) != "base" && !$0.isEmpty }
        guard !wanted.isEmpty else { return fallback }

        if let exact = candidates.first(where: { normal($0) == wanted }) { return exact }
        let wantedBase = base(wanted)
        if let bare = candidates.first(where: { normal($0) == wantedBase }) { return bare }
        if let regional = candidates
            .filter({ base($0) == wantedBase })
            .sorted(by: { normal($0) < normal($1) })
            .first {
            return regional
        }
        return fallback
    }

    /// `key` as the catalog has it for `target`'s language, or `key` itself (English) when the
    /// bundle has no localization for that language or no translation of the key.
    static func localized(_ key: String, forTarget target: String, bundle: Bundle = .main) -> String {
        let chosen = localization(forTarget: target, available: bundle.localizations)
        guard let path = bundle.path(forResource: chosen, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else { return key }
        return languageBundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// The line said to the other person, in the language they are being translated into.
    static func listenerLine(forTarget target: String, bundle: Bundle = .main) -> String {
        localized(listenerLineKey, forTarget: target, bundle: bundle)
    }

    /// The label on the other person's half of the two-way caption split, in their language.
    static func captionLabel(forTarget target: String, bundle: Bundle = .main) -> String {
        localized(captionLabelKey, forTarget: target, bundle: bundle)
    }

    /// Whether spoken translation audio will come out of the phone's own loudspeaker — where the
    /// other person, not only the wearer, hears it.
    ///
    /// Mirrors what `TextToSpeechService` does with the route: with "Glasses Only Audio" on, speech
    /// plays on the glasses or not at all; otherwise a route that is already the loudspeaker, or
    /// that has nothing better than the earpiece (which the speech service overrides to the
    /// loudspeaker, `MicRoutePolicy.shouldOverrideToSpeaker`), is the loudspeaker. Glasses,
    /// AirPods, headphones and a car keep the translation with the wearer.
    static func playsFromPhoneSpeaker(outputs: [AVAudioSession.Port], glassesOnlyAudio: Bool) -> Bool {
        if glassesOnlyAudio { return false }
        if outputs.contains(.builtInSpeaker) { return true }
        return MicRoutePolicy.shouldOverrideToSpeaker(outputs: outputs)
    }
}
