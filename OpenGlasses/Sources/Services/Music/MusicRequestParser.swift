import Foundation

/// Turns what the wearer (or the model) said into a `MusicPlayRequest` and a target (Plan GS).
///
/// Pure string work. The model usually passes a clean `query` and an action that fixes the kind,
/// but it also forwards phrases verbatim ("the album Rumours by Fleetwood Mac on the kitchen
/// speaker"), so both shapes have to parse to the same request.
enum MusicRequestParser {

    // MARK: - Targets

    /// A provider or app the wearer named.
    enum ServiceHint: Equatable, Sendable {
        case appleMusic
        case homeAssistant
        /// A service Avenkin cannot control directly, by its spoken name ("Spotify").
        case unsupported(String)
    }

    struct Target: Equatable, Sendable {
        var service: ServiceHint?
        /// A speaker name ("kitchen"), or nil.
        var device: String?
    }

    /// Services people name that have no route from the phone. Spoken names, lowercased.
    static let unsupportedServices: [(spoken: String, display: String)] = [
        ("spotify", "Spotify"),
        ("youtube music", "YouTube Music"),
        ("youtube", "YouTube"),
        ("tidal", "Tidal"),
        ("deezer", "Deezer"),
        ("pandora", "Pandora"),
        ("amazon music", "Amazon Music"),
        ("soundcloud", "SoundCloud"),
    ]

    private static let appleMusicNames = ["apple music", "the music app", "my phone", "the phone", "my iphone", "the iphone"]

    /// Resolve a service argument as the model passed it ("spotify", "apple_music", "home assistant").
    static func service(named raw: String?) -> ServiceHint? {
        guard let raw else { return nil }
        let value = normalizedWords(raw.replacingOccurrences(of: "_", with: " "))
        guard !value.isEmpty else { return nil }
        if value == "apple music" || value == "applemusic" || value == "music" || value == "phone" || value == "iphone" {
            return .appleMusic
        }
        if value == "home assistant" || value == "homeassistant" || value == "ha" || value == "speaker" {
            return .homeAssistant
        }
        if let match = unsupportedServices.first(where: { value == $0.spoken || value.hasPrefix($0.spoken) }) {
            return .unsupported(match.display)
        }
        return nil
    }

    /// Split a trailing "on <target>" / "in <target>" off a phrase: "rumours on the kitchen speaker"
    /// → ("rumours", device "kitchen"); "discover weekly on spotify" → ("discover weekly", Spotify).
    static func extractTarget(from phrase: String) -> (rest: String, target: Target) {
        let lower = spokenForm(phrase)
        for connector in [" on ", " in ", " through ", " using ", " with "] {
            guard let range = lower.range(of: connector, options: .backwards) else { continue }
            let tail = String(lower[range.upperBound...])
            let head = String(lower[..<range.lowerBound])
            guard !head.isEmpty else { continue }
            if let target = parseTargetTail(tail) {
                return (head, target)
            }
        }
        // "spotify" alone, or "play spotify".
        if let service = service(named: lower), case .unsupported = service {
            return ("", Target(service: service, device: nil))
        }
        return (lower, Target())
    }

    /// Read a `device` argument as the model passed it: "the kitchen speaker" → device "kitchen",
    /// "spotify" → the service, "my phone" → Apple Music, anything else → that speaker name.
    static func deviceTarget(_ raw: String) -> Target {
        let spoken = spokenForm(raw)
        if let target = parseTargetTail(spoken) { return target }
        var name = spoken
        for article in ["the ", "my "] where name.hasPrefix(article) {
            name = String(name.dropFirst(article.count))
        }
        return Target(service: nil, device: name.isEmpty ? nil : name)
    }

    private static func parseTargetTail(_ tail: String) -> Target? {
        var words = tail
        for article in ["the ", "my "] where words.hasPrefix(article) {
            words = String(words.dropFirst(article.count))
        }
        if let hint = service(named: words) {
            // "on my phone" is Apple Music; "on spotify" names a service.
            if case .homeAssistant = hint { return Target(service: .homeAssistant, device: nil) }
            return Target(service: hint, device: nil)
        }
        if appleMusicNames.contains(tail) || appleMusicNames.contains(words) {
            return Target(service: .appleMusic, device: nil)
        }
        for suffix in [" speakers", " speaker", " sonos", " homepod", " player"] where words.hasSuffix(suffix) {
            let name = String(words.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            return Target(service: nil, device: name.isEmpty ? words : name)
        }
        return nil
    }

    // MARK: - Requests

    /// Parse a play-by-name phrase. `kind` comes from the action (`play_album` → `.album`) and
    /// wins over words in the phrase; `.any` lets the phrase decide.
    static func request(from rawPhrase: String, kind explicitKind: MusicItemKind = .any) -> MusicPlayRequest {
        var phrase = spokenForm(rawPhrase)
        var shuffle = false

        for lead in ["play me ", "play ", "put on ", "shuffle ", "listen to "] where phrase.hasPrefix(lead) {
            if lead == "shuffle " { shuffle = true }
            phrase = String(phrase.dropFirst(lead.count))
        }
        if phrase.hasPrefix("some ") { phrase = String(phrase.dropFirst(5)) }

        var kind = explicitKind
        var artistFromPhrase: String?

        // Leading kind words: "the album x", "album x", "the song x", "the playlist x", "artist x".
        let leadingKinds: [(String, MusicItemKind)] = [
            ("the album ", .album), ("album ", .album),
            ("the song ", .song), ("song ", .song), ("the track ", .song), ("track ", .song),
            ("the playlist ", .playlist), ("playlist ", .playlist),
            ("the artist ", .artist), ("artist ", .artist),
            ("the station ", .station), ("radio station ", .station), ("station ", .station),
        ]
        for (word, detected) in leadingKinds where phrase.hasPrefix(word) {
            phrase = String(phrase.dropFirst(word.count))
            if kind == .any { kind = detected }
            break
        }

        // "songs by x" / "music by x" / "something by x" → the artist.
        for lead in ["songs by ", "music by ", "something by ", "anything by ", "tracks by "] where phrase.hasPrefix(lead) {
            artistFromPhrase = String(phrase.dropFirst(lead.count))
            phrase = artistFromPhrase ?? phrase
            if kind == .any { kind = .artist }
            shuffle = true
            break
        }

        // Trailing kind words: "x album", "my x playlist", "x radio", "x station".
        let trailingKinds: [(String, MusicItemKind)] = [
            (" album", .album), (" playlist", .playlist), (" radio station", .station),
            (" radio", .station), (" station", .station),
        ]
        for (word, detected) in trailingKinds where phrase.hasSuffix(word) && phrase.count > word.count {
            phrase = String(phrase.dropLast(word.count))
            if kind == .any || kind == detected { kind = detected }
            break
        }
        // "my discover weekly playlist": the possessive is not part of the name. A leading "the"
        // is kept — it belongs to names like "The Dark Side of the Moon".
        if kind == .playlist, phrase.hasPrefix("my ") { phrase = String(phrase.dropFirst(3)) }

        phrase = phrase.trimmingCharacters(in: .whitespaces)
        if kind == .artist { shuffle = true }

        var title = phrase
        var artist: String?
        if kind != .artist, artistFromPhrase == nil, let byRange = phrase.range(of: " by ", options: .backwards) {
            let left = String(phrase[..<byRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(phrase[byRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty {
                title = left
                artist = right
            }
        }
        return MusicPlayRequest(kind: kind, phrase: phrase, title: title, artist: artist, shuffle: shuffle)
    }

    // MARK: - Normalisation

    /// Lowercased and single-spaced, with sentence punctuation removed but apostrophes, accents
    /// and ampersands kept — this is what goes to a search, and "Don't Stop Me Now" has to still
    /// find "Don't". Comparison uses the heavier `normalizedWords`.
    static func spokenForm(_ text: String) -> String {
        let stripped = text.lowercased().map { character -> Character in
            ",.!?\";:\u{201C}\u{201D}".contains(character) ? " " : character
        }
        return String(stripped).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Lowercase, folded, punctuation turned to spaces, single-spaced. Apostrophes are dropped
    /// rather than spaced so "don't" stays one word.
    static func normalizedWords(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
        var out = ""
        for scalar in folded.unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" { continue }
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }
}
