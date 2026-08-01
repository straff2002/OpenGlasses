import Foundation

/// Plan BY P3 — pure direction/leg routing shared by both tiers and both surfaces.
enum TranslationRouting {

    /// The session direction the current settings describe.
    static func activeDirection(twoWayEnabled: Bool, languageA: String, languageB: String,
                                oneWayTarget: String) -> TranslationDirectionPolicy {
        twoWayEnabled ? .twoWay(languageA, languageB) : .oneWay(target: oneWayTarget)
    }

    /// Reads config. `languageA` is the wearer's own language in two-way mode.
    static func currentDirection() -> TranslationDirectionPolicy {
        activeDirection(twoWayEnabled: Config.translationTwoWayEnabled,
                        languageA: Config.translationLanguageA,
                        languageB: Config.translationLanguageB,
                        oneWayTarget: Config.translationTargetLanguage)
    }

    /// Whether a segment detected as `detected` renders in the wearer's language — the leg the
    /// in-lens HUD shows (the phone shows both). One-way sessions render everything for the
    /// wearer; an undetectable language defaults to the wearer leg (showing too much beats
    /// silently hiding a caption).
    static func isWearerLeg(detected: String?, direction: TranslationDirectionPolicy,
                            wearerLanguage: String) -> Bool {
        switch direction {
        case .oneWay:
            return true
        case .twoWay:
            guard let render = direction.renderLanguage(forDetected: detected) else { return true }
            return render.hasPrefix(wearerLanguage) || wearerLanguage.hasPrefix(render)
        }
    }
}
