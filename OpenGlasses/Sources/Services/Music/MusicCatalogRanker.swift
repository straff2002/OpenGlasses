import Foundation

/// Picks the one catalogue result to play for a spoken request (Plan GS). Pure.
///
/// The catalogue's own order is a popularity guess; for a spoken request an exact name beats it.
/// "Play Yesterday" should play the song called Yesterday, not a more popular song with the word
/// in it, and "Rumours by Fleetwood Mac" should not play a cover by someone else because the cover
/// ranks first. So the score is, in order of weight:
///
/// 1. the kind the wearer asked for (an explicit "album" or "playlist" filters, it does not nudge);
/// 2. an exact title match, then a title that starts with or contains the words;
/// 3. the artist, when one was named — a named artist that does not match is a strong penalty;
/// 4. popularity, as a small tie-breaker.
///
/// Titles are compared after normalisation: case, accents, punctuation, and trailing edition tags
/// such as "(Remastered 2011)" or "- Single" are ignored.
enum MusicCatalogRanker {

    struct Scored: Equatable {
        let candidate: MusicCatalogCandidate
        let score: Int
    }

    /// The minimum score worth playing. Below it nothing sensible matched, and saying so beats
    /// playing something random.
    static let playableThreshold = 20

    /// The best candidate, or nil when nothing clears the threshold.
    static func best(for request: MusicPlayRequest, among candidates: [MusicCatalogCandidate]) -> MusicCatalogCandidate? {
        ranked(for: request, among: candidates).first.flatMap { $0.score >= playableThreshold ? $0.candidate : nil }
    }

    /// Every eligible candidate, best first. Ties keep the service's order.
    static func ranked(for request: MusicPlayRequest, among candidates: [MusicCatalogCandidate]) -> [Scored] {
        let eligible = candidates.filter { request.kind == .any || $0.kind == request.kind }
        return eligible.enumerated()
            .map { (offset: $0.offset, scored: Scored(candidate: $0.element, score: score($0.element, for: request))) }
            .sorted { lhs, rhs in
                lhs.scored.score != rhs.scored.score ? lhs.scored.score > rhs.scored.score : lhs.offset < rhs.offset
            }
            .map(\.scored)
    }

    /// The better of the two readings of the request (see `MusicPlayRequest`).
    static func score(_ candidate: MusicCatalogCandidate, for request: MusicPlayRequest) -> Int {
        let whole = score(candidate, title: request.phrase, artist: nil, kind: request.kind)
        guard let artist = request.artist else { return whole }
        let split = score(candidate, title: request.title, artist: artist, kind: request.kind)
        return max(whole, split)
    }

    private static func score(_ candidate: MusicCatalogCandidate, title wantedTitle: String,
                              artist wantedArtist: String?, kind: MusicItemKind) -> Int {
        let want = comparable(wantedTitle)
        let have = comparable(candidate.title)
        guard !want.isEmpty else { return 0 }

        var score = 0
        if have == want {
            score += 100
        } else if have.hasPrefix(want + " ") || want.hasPrefix(have + " ") {
            score += 45
        } else if (" " + have + " ").contains(" " + want + " ") {
            score += 30
        } else if wordOverlap(want, have) >= 0.6 {
            score += 15
        }

        if let wantedArtist {
            let wantArtist = comparable(wantedArtist)
            let haveArtist = candidate.artist.map(comparable) ?? ""
            if !haveArtist.isEmpty, haveArtist == wantArtist || (" " + haveArtist + " ").contains(" " + wantArtist + " ") {
                score += 60
            } else {
                score -= 50
            }
        }

        // With no kind asked for, a small prior: a song is the usual intent, then an artist whose
        // name is exactly what was said, then collections.
        if kind == .any {
            switch candidate.kind {
            case .song: score += 6
            case .artist: score += have == want ? 8 : 0
            case .album: score += 4
            case .playlist: score += 2
            case .station, .any: score += 0
            }
        }

        score -= min(candidate.popularityRank, 10) * 2
        return score
    }

    // MARK: - Normalisation

    /// Normalised for comparison: `MusicRequestParser.normalizedWords`, edition tags stripped.
    static func comparable(_ title: String) -> String {
        var text = title
        // Bracketed tags: "(Remastered 2011)", "[Live]", "(feat. X)".
        while let open = text.firstIndex(where: { $0 == "(" || $0 == "[" }),
              let close = text[open...].firstIndex(where: { $0 == ")" || $0 == "]" }) {
            text.removeSubrange(open...close)
        }
        var words = MusicRequestParser.normalizedWords(text)
        // Unbracketed tags ("Yesterday - Remastered 2009", "Song - Single") cut everything after.
        for tag in [" remaster", " feat ", " deluxe edition"] {
            if let range = words.range(of: tag) { words = String(words[..<range.lowerBound]) }
        }
        for tag in [" single", " ep", " deluxe"] where words.hasSuffix(tag) {
            words = String(words.dropLast(tag.count))
        }
        return words.trimmingCharacters(in: .whitespaces)
    }

    private static func wordOverlap(_ a: String, _ b: String) -> Double {
        let left = Set(a.split(separator: " "))
        let right = Set(b.split(separator: " "))
        guard !left.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.count)
    }
}
