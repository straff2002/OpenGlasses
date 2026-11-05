import Foundation

/// Where a walking turn reaches the wearer, read from what is actually there — the Plan GM rule:
/// glasses-free use is the baseline, every other surface is an extra that is named only while it
/// is present, and an unavailable state says why.
///
/// Today a turn reaches the wearer two ways: spoken (Voice Cues) and in-lens (a glasses display,
/// native or the web mirror). The phone screen shows nothing during a walk, so with neither the
/// guidance is silent and the copy says so instead of promising a lens. The watch's live route
/// (Plan GM P1b) joins this list when it ships; until then the wrist is not named.
struct WalkingTurnSurfaces: Equatable, Sendable {
    /// Turns are spoken (`Config.navigationVoiceCues`).
    var voiceCues: Bool
    /// A glasses display is enabled and connected (or its web mirror is on), so
    /// `GlassesDisplayService.showNavigation` reaches a lens.
    var inLens: Bool

    /// Neither surface is present: a walk would run with nothing spoken and nothing shown.
    var isSilent: Bool { !voiceCues && !inLens }

    /// The Walking Navigation settings footer, naming only the surfaces that are there.
    var footer: String {
        switch (voiceCues, inLens) {
        case (true, true):
            return String(localized: "Say \u{201C}navigate to \u{2026}\u{201D} to start walking directions — each turn shows in-lens and is spoken as you approach it. Walking routes only; driving stays with CarPlay. Routing needs a network connection.")
        case (true, false):
            return String(localized: "Say \u{201C}navigate to \u{2026}\u{201D} to start walking directions — each turn is spoken as you approach it. Walking routes only; driving stays with CarPlay. Routing needs a network connection.")
        case (false, true):
            return String(localized: "Say \u{201C}navigate to \u{2026}\u{201D} to start walking directions — each turn shows in-lens. Voice Cues are off, so turns are not spoken. Walking routes only; driving stays with CarPlay. Routing needs a network connection.")
        case (false, false):
            return String(localized: "Say \u{201C}navigate to \u{2026}\u{201D} to start walking directions. Voice Cues are off and nothing else shows the turns, so directions would be silent — turn Voice Cues on to hear each turn. Walking routes only; driving stays with CarPlay. Routing needs a network connection.")
        }
    }

    /// The recents footer: the glasses menu is a lens surface, so it is named only with one.
    var recentsFooter: String? {
        inLens ? String(localized: "Recents also appear in the glasses menu under Navigate.") : nil
    }
}
