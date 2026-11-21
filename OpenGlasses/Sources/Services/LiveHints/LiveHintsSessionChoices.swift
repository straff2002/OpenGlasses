import Foundation

// What the session sheet offers and what it starts with (Plan MO P2): the mode, the documents, the
// hint language, where hints go, which mic listens, the talk note and the keywords. Pure, so the
// defaults and the rules behind each control are tested without a screen.

/// Where a hint goes (§6, decision 3).
enum HintDelivery: String, CaseIterable, Equatable, Sendable {
    /// On the lens while a Display is connected and showing; in the ear when it isn't.
    case lens
    /// In the ear, even with a Display connected.
    case ear

    /// Whether a hint goes to the lens now: the wearer's choice, and a lens that can take it. A
    /// Display that goes away mid-session sends hints to the ear rather than nowhere.
    static func usesLens(_ choice: HintDelivery, lensAvailable: Bool) -> Bool {
        choice == .lens && lensAvailable
    }
}

/// Which microphone hears the room (§7, decision 4).
enum HintMic: String, CaseIterable, Equatable, Sendable {
    /// The phone's own mic: it hears the other person, and the glasses stay on full-quality audio.
    case phone
    /// The glasses' hands-free mic. Offered only with glasses connected, with its caveat.
    case glasses

    /// The route the idle listener waits on during a session.
    var route: MicRoute {
        switch self {
        case .phone: return .phone
        case .glasses: return .glasses
        }
    }
}

/// The documents a session searches (§5 step 1, decision 5): the active project's by default, or
/// the documents the wearer picked on the sheet.
struct HintDocumentScope: Equatable, Sendable {
    /// The namespace searched, or nil when `documentIds` alone decide.
    var namespace: String?
    /// The documents picked on the sheet, or nil for the whole namespace.
    var documentIds: [String]?

    /// The active project's namespace (`global` with no project), unless documents were picked.
    static func resolve(chosen: [String]?, activeProject: String?) -> HintDocumentScope {
        if let chosen, !chosen.isEmpty {
            return HintDocumentScope(namespace: nil, documentIds: chosen)
        }
        return HintDocumentScope(namespace: activeProject ?? "global", documentIds: nil)
    }
}

/// Everything the session sheet sets, with its defaults.
struct LiveHintsSessionChoices: Equatable, Sendable {
    var mode: HintMode = .conversation
    /// The documents picked on the sheet; nil (or empty) is the active project.
    var documentIds: [String]?
    /// The language hints are written in; nil is the conversation's own.
    var hintLanguageCode: String?
    var delivery: HintDelivery = .ear
    var mic: HintMic = .phone
    /// A note of the talk, saved at stop (§9, decision 7). Off by default.
    var talkNote = false
    var keywords: [String] = []

    /// What the sheet opens with: the conversation mode, the active project, the conversation's
    /// language, the lens when a Display is connected and the ear otherwise, the phone's mic, no
    /// talk note and no keywords.
    static func defaults(displayConnected: Bool) -> LiveHintsSessionChoices {
        var choices = LiveHintsSessionChoices()
        choices.delivery = displayConnected ? .lens : .ear
        return choices
    }

    /// Why Start is not offered, or nil when it is. Keyword mode listens for nothing without a
    /// keyword.
    var startBlocker: StartBlocker? {
        mode == .keyword && keywords.isEmpty ? .noKeywords : nil
    }

    enum StartBlocker: Equatable, Sendable {
        case noKeywords
    }

    /// The choices with what the sheet may not offer taken back to the default: the glasses' mic
    /// without glasses connected, and a talk note in Medical Compliance mode.
    func applying(glassesConnected: Bool, medicalCompliance: Bool) -> LiveHintsSessionChoices {
        var choices = self
        if !glassesConnected { choices.mic = .phone }
        if medicalCompliance { choices.talkNote = false }
        return choices
    }

    /// A keyword the wearer typed, added once: blanks and a repeat (folded) are not added.
    mutating func addKeyword(_ raw: String) {
        let keyword = HintText.collapsingWhitespace(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !HintText.words(keyword).isEmpty else { return }
        let key = HintText.normalized(keyword)
        guard !keywords.contains(where: { HintText.normalized($0) == key }) else { return }
        keywords.append(keyword)
    }

    /// The session's settings for these choices.
    var settings: LiveHintsService.Settings {
        var settings = LiveHintsService.Settings(mode: mode, keywords: keywords, hintLanguageCode: hintLanguageCode)
        settings.delivery = delivery
        settings.mic = mic
        settings.talkNote = talkNote
        settings.documentIds = documentIds?.isEmpty == true ? nil : documentIds
        return settings
    }
}

/// The hint languages the sheet offers besides the conversation's own: the app's interface
/// languages, named by the system in the wearer's language, so nothing new needs translating.
enum HintLanguageOptions {
    static let codes = [
        "en", "es", "fr", "de", "it", "pt", "nl", "pl", "sv", "da", "nb", "fi", "tr", "ru",
        "uk", "ar", "he", "hi", "ja", "ko", "zh-Hans", "zh-Hant", "th", "vi", "id",
    ]

    /// `code` named in `locale`'s language, or the code itself when the system has no name.
    static func name(_ code: String, in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: code) ?? code
    }
}

/// What the mode picker says about voices (§3): with diarization the wearer marks their own voice
/// on the session screen; without it every question is hinted.
enum HintVoiceNote: Equatable, Sendable {
    case tellsVoicesApart
    case cantTellVoicesApart

    static func `for`(diarizationOn: Bool) -> HintVoiceNote {
        diarizationOn ? .tellsVoicesApart : .cantTellVoicesApart
    }
}

/// Whether the background stop applies (§1): the session stops once the app has been away as long
/// as captions are allowed to be, by the same rule (`CaptionPresenceGate`), because past that the
/// captions it listens through are suspended and nothing would be hinted.
enum LiveHintsPresenceRule {
    static func shouldStop(mode: EngagementMode, sessionRunning: Bool) -> Bool {
        sessionRunning && CaptionPresenceGate.shouldSuspend(mode: mode)
    }
}
