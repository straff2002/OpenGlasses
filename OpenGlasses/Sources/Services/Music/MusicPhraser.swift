import Foundation

/// Every sentence the music layer speaks (Plan GS). Pure, so the copy is pinned by tests and
/// written for the ear: one sentence where one will do, no internal names, no plan letters.
enum MusicPhraser {

    // MARK: - Refusals and redirections

    /// A service Avenkin has no route to. Generic on purpose: it does not promise any other
    /// assistant can do it, and it offers what does work.
    static func cannotControl(_ service: String) -> String {
        "Avenkin can't control \(service) directly. Your glasses' temple controls still work on whatever's playing, "
            + "and you can set a Home Assistant speaker as your music provider in Settings."
    }

    static let speakersNeedHomeAssistant =
        "Playing on a speaker needs Home Assistant, which isn't set up. You can add it in Settings, under Services."

    static let noSpeakers =
        "I couldn't find any Home Assistant speakers you've made available. You can choose them in Settings, under Music."

    static func noSpeakerNamed(_ name: String, available: [MusicSpeaker]) -> String {
        guard !available.isEmpty else { return "I couldn't find a speaker called \(name)." }
        return "I couldn't find a speaker called \(name). Your speakers are \(list(available.map(\.name)))."
    }

    static func askWhichSpeaker(_ speakers: [MusicSpeaker]) -> String {
        "Which speaker: \(list(speakers.map(\.name), conjunction: "or"))?"
    }

    static func speakerList(_ speakers: [MusicSpeaker]) -> String {
        guard !speakers.isEmpty else { return noSpeakers }
        return speakers.count == 1
            ? "You have one speaker available: \(speakers[0].name)."
            : "Your speakers are \(list(speakers.map(\.name)))."
    }

    /// The one sentence when the catalogue needs a subscription and the library had nothing.
    static func needsSubscription(_ request: MusicPlayRequest) -> String {
        "I couldn't find \(quoted(request)) in your library, and playing from the full Apple Music catalogue needs an Apple Music subscription."
    }

    static func notInLibrary(_ request: MusicPlayRequest) -> String {
        "I couldn't find \(quoted(request)) in your library."
    }

    static func notFound(_ request: MusicPlayRequest) -> String {
        "I couldn't find \(quoted(request)) on Apple Music or in your library."
    }

    static let accessDenied =
        "Avenkin doesn't have access to Apple Music. You can allow it in the iPhone Settings app, under Avenkin."

    static let accessNeedsPhone =
        "To use Apple Music, open Avenkin on your phone once and allow access."

    static let catalogueBlockedLocalOnly =
        "Medical Local Only is on, so I only searched your own library."

    static let catalogueUnavailable =
        "Apple Music isn't answering right now, so I only searched your own library."

    // MARK: - Actions

    static func playing(_ match: MusicCatalogCandidate) -> String {
        switch match.kind {
        case .song: return "Playing \(match.title)\(by(match.artist))."
        case .album: return "Playing the album \(match.title)\(by(match.artist))."
        case .artist: return "Playing \(match.title)."
        case .playlist: return "Playing the playlist \(match.title)."
        case .station: return "Playing the station \(match.title)."
        case .any: return "Playing \(match.title)."
        }
    }

    static func playingFromLibrary(_ match: MusicLibraryMatch) -> String {
        switch match.kind {
        case .artist:
            return match.trackCount == 1
                ? "Playing the one song by \(match.title) in your library."
                : "Shuffling \(match.trackCount) songs by \(match.title) from your library."
        case .album: return "Playing the album \(match.title)\(by(match.artist)) from your library."
        case .playlist: return "Playing your playlist \(match.title)."
        default: return "Playing \(match.title)\(by(match.artist)) from your library."
        }
    }

    static func addedToLibrary(title: String, artist: String?) -> String {
        "Added \(title)\(by(artist)) to your library."
    }

    static func alreadyInLibrary(title: String) -> String {
        "\(title) is already in your library."
    }

    /// "Like" has no Apple Music API for apps; the honest nearest thing is adding it.
    static let likeIsAddToLibrary =
        "Apps can't love a song in Apple Music, so I added it to your library instead."

    static let addNeedsSubscription =
        "Adding music to your library needs an Apple Music subscription."

    static let nothingToAdd =
        "Nothing from Apple Music is playing, so there's nothing to add."

    static func searchResults(_ candidates: [MusicCatalogCandidate]) -> String {
        guard !candidates.isEmpty else { return "I didn't find anything on Apple Music for that." }
        let items = candidates.map { candidate -> String in
            let noun = candidate.kind == .song || candidate.kind == .any ? "" : " (\(candidate.kind.rawValue))"
            return "\(candidate.title)\(by(candidate.artist))\(noun)"
        }
        return "On Apple Music: \(items.joined(separator: "; "))."
    }

    static func librarySearchResults(_ matches: [MusicLibraryMatch], query: String) -> String {
        guard !matches.isEmpty else { return "No songs matching \(query) in your library." }
        let items = matches.map { "\($0.title)\(by($0.artist))" }
        return "In your library: \(items.joined(separator: "; "))."
    }

    static func sentToSpeaker(_ speaker: MusicSpeaker, _ what: String) -> String {
        "\(what) on \(speaker.name)."
    }

    static func speakerCannot(_ speaker: MusicSpeaker, _ what: String) -> String {
        "\(speaker.name) doesn't support \(what)."
    }

    // MARK: - Now playing

    /// "Playing Blinding Lights by The Weeknd, from After Hours (2020) — 1 minute in, of 3 minutes 20."
    static func nowPlaying(_ summary: NowPlayingSummary?) -> String {
        guard let summary, summary.hasTrack, summary.state != .stopped else {
            return nothingPlaying
        }
        var sentence: String
        let track = [summary.title, summary.artist.map { "by \($0)" }].compactMap { $0 }.joined(separator: " ")
        switch summary.state {
        case .playing: sentence = "Playing \(track)"
        case .paused: sentence = "Paused on \(track)"
        case .stopped: sentence = track
        }
        if let album = summary.album, !album.isEmpty, album != summary.title {
            sentence += ", from \(album)"
            if let year = summary.releaseYear { sentence += " (\(year))" }
        }
        if let speaker = summary.speakerName {
            sentence += " on \(speaker)"
            if let app = summary.sourceApp, !app.isEmpty { sentence += " through \(app)" }
        }
        if let elapsed = summary.elapsed, let duration = summary.duration, duration > 0, elapsed >= 0 {
            sentence += " — \(clock(elapsed)) in, of \(clock(duration))"
        }
        return sentence + "."
    }

    /// Honest about what the phone cannot see: another app's playback is invisible to Avenkin.
    static let nothingPlaying =
        "Nothing is playing in Apple Music. If another app is playing, Avenkin can't see what it is, "
            + "but your glasses' temple controls still work on it."

    /// "3 minutes 20", "1 minute", "45 seconds".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let secs = total % 60
        if minutes == 0 { return "\(secs) second\(secs == 1 ? "" : "s")" }
        let minutePart = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        return secs == 0 ? minutePart : "\(minutePart) \(secs)"
    }

    // MARK: - Helpers

    private static func by(_ artist: String?) -> String {
        guard let artist, !artist.isEmpty else { return "" }
        return " by \(artist)"
    }

    private static func quoted(_ request: MusicPlayRequest) -> String {
        if let noun = request.kind.spokenNoun, request.kind != .artist { return "the \(noun) \(request.phrase)" }
        if request.kind == .artist { return "anything by \(request.phrase)" }
        return request.phrase
    }

    static func list(_ names: [String], conjunction: String = "and") -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) \(conjunction) \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", \(conjunction) " + names.last!
        }
    }
}
