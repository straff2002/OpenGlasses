import Foundation

/// The answer as the reading view lays it out (Plan MU §2): its prose with every `Source:` marker
/// taken out, and the sources it cited, for one **source tile** at the end of the answer. Pure.
///
/// - **Every marker goes**, on a line of its own (as `VaultRetriever` attaches it) or inside a
///   sentence (as a model writes it: "… reset the board. Source: Invented Unit Guide, page 20.").
///   The sources are what `CitationLineParser.sourceBodies(of:)` reads after each marker, so the
///   tile names exactly what the phone's citation chips do.
/// - **A sentence that ends in "Source: …" keeps its words up to the marker**, closed with a full
///   stop when nothing else follows. Prose after the citation ("… page 20. Then restart it.") stays
///   where it was, as does the rest of a sentence a bracketed `(Source: …)` sat inside.
/// - **The tile** is "Source: …", several joined with "; ", at most `maxLines` lines, cut with "…".
/// - Only the lens: the spoken answer and the phone's chat keep the text as it was.
struct LensSourceTile: Equatable {
    /// The answer with the markers taken out, its paragraphs kept (one per line, as before).
    let prose: String
    /// The sources, in order, each once.
    let sources: [String]

    /// Plan MU §2: the tile is at most three lines.
    static let maxLines = 3

    /// What a `Source:` marker looks like: not inside a word, so "Resources: 2" is prose.
    private static let markerPattern = #"(?i)(?<![\p{L}\p{N}])sources?:"#

    static func split(_ text: String) -> LensSourceTile {
        var proseLines: [String] = []
        var sources: [String] = []
        var seen = Set<String>()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for line in lines {
            let markers = markerRanges(in: line)
            guard !markers.isEmpty else {
                proseLines.append(line)
                continue
            }
            for body in CitationLineParser.sourceBodies(of: line) {
                let cleaned = body.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_"))
                guard !cleaned.isEmpty, !CitationLineParser.nonCitations.contains(cleaned.lowercased()),
                      seen.insert(cleaned.lowercased()).inserted else { continue }
                sources.append(cleaned)
            }
            let kept = prose(of: line, markers: markers)
            // A line that was only a citation leaves nothing behind (not even a blank paragraph).
            if !kept.isEmpty { proseLines.append(kept) }
        }
        return LensSourceTile(prose: proseLines.joined(separator: "\n"), sources: sources)
    }

    /// The tile's text: "Source: a" or "Sources: a; b". Nil with no source.
    var text: String? {
        guard !sources.isEmpty else { return nil }
        let label = sources.count == 1
            ? String(localized: "Source:", comment: "Glasses: starts the line naming the document an answer came from.")
            : String(localized: "Sources:", comment: "Glasses: starts the line naming the documents an answer came from.")
        return label + " " + sources.joined(separator: "; ")
    }

    /// The tile's lines at `maxChars` a line: at most `maxLines`, the last ending in "…" when the
    /// sources run on.
    func lines(maxChars: Int) -> [String] {
        guard let text else { return [] }
        let chars = max(2, maxChars)
        let display = HUDAnswerPager.displayLines(for: text, maxChars: chars)
        guard display.count > Self.maxLines else { return display }
        var shown = Array(display.prefix(Self.maxLines))
        let last = shown[shown.count - 1]
        let room = chars - 1
        var cut = last.count > room ? String(last.prefix(room)) : last
        // Not inside a word when there is a space to cut at.
        if last.count > room, let space = cut.lastIndex(of: " "), space > cut.startIndex {
            cut = String(cut[cut.startIndex..<space])
        }
        shown[shown.count - 1] = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ;,")) + "…"
        return shown
    }

    // MARK: - Taking the markers out of a line

    private static func markerRanges(in line: String) -> [Range<String.Index>] {
        var markers: [Range<String.Index>] = []
        var from = line.startIndex
        while let found = line.range(of: markerPattern, options: .regularExpression, range: from..<line.endIndex) {
            markers.append(found)
            from = found.upperBound
        }
        return markers
    }

    /// Characters a sentence leaves before its citation that only led into it.
    private static let leadIns = CharacterSet(charactersIn: " \t—–-,;:([*_")
    private static let sentenceStops: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    /// The line's prose: what comes before its first marker, then whatever prose follows each
    /// citation.
    private static func prose(of line: String, markers: [Range<String.Index>]) -> String {
        guard let first = markers.first else { return line }
        let before = String(line[line.startIndex..<first.lowerBound])
        var pieces: [String] = []
        let lead = trimmingTrailing(before, leadIns)
        if !lead.isEmpty { pieces.append(lead) }
        for (index, marker) in markers.enumerated() {
            let end = index + 1 < markers.count ? markers[index + 1].lowerBound : line.endIndex
            let segment = String(line[marker.upperBound..<end])
            let opensBracket = line[line.startIndex..<marker.lowerBound]
                .trimmingCharacters(in: .whitespaces).hasSuffix("(")
            let after = remainder(after: segment, bracketed: opensBracket)
            if !after.isEmpty { pieces.append(after) }
        }
        return join(pieces)
    }

    /// The prose after a citation in `segment` (the text from a marker to the next one): after the
    /// bracket that closes a `(Source: …)`, or after the sentence the citation ends with.
    private static func remainder(after segment: String, bracketed: Bool) -> String {
        if bracketed, let close = segment.firstIndex(of: ")") {
            return String(segment[segment.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        var body = segment.trimmingCharacters(in: .whitespaces)
        // A recognised-from-a-scan note belongs with the citation, up to its own bracket.
        if let note = body.range(of: #"(?i)\(text recogni[sz]ed"#, options: .regularExpression) {
            guard let close = body[note.lowerBound...].firstIndex(of: ")") else { return "" }
            body = String(body[body.index(after: close)...])
            return body.trimmingCharacters(in: CharacterSet(charactersIn: " \t."))
        }
        let citation = CitationLineParser.closingSentence(body)
        guard citation.count < body.count else { return "" }
        return String(body.dropFirst(citation.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t."))
    }

    /// The pieces as one line: a piece that carries on a sentence (lower case, or punctuation) joins
    /// the one before; one that starts a sentence follows a closed one; the line ends closed.
    private static func join(_ pieces: [String]) -> String {
        var text = ""
        for piece in pieces {
            guard let first = piece.first else { continue }
            if text.isEmpty {
                text = piece
            } else if first.isPunctuation {
                text += piece
            } else if first.isLowercase || first.isNumber {
                text += " " + piece
            } else {
                text = closed(text) + " " + piece
            }
        }
        return text.isEmpty ? text : closed(text)
    }

    private static func trimmingTrailing(_ text: String, _ set: CharacterSet) -> String {
        var scalars = Substring(text)
        while let last = scalars.unicodeScalars.last, set.contains(last) { scalars = scalars.dropLast() }
        return String(scalars)
    }

    private static func closed(_ text: String) -> String {
        guard let last = text.last else { return text }
        if sentenceStops.contains(last) || last == ")" || last == "\"" || last == "”" { return text }
        return text + "."
    }
}
