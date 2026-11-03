import Foundation

/// Plan KK — the deterministic check behind an accepted summary: the figures and codes the wearer
/// said in a chunk must still be in its note. Pure.
///
/// A technician's readings and part numbers are the one thing a paraphrase must not lose, and this
/// check needs no model to trust. It reads the chunk's **user** messages only — a figure the
/// assistant said is either an answer the wearer will ask for again or a mistake, and neither is a
/// reason to repeat it — and looks for numbers with units (52 psi, 3.2 A, 120V, -18°C, 1/2 in) and
/// mixed letter-and-digit codes of three characters or more (model, serial, part and fault codes).
/// Any the summary lost come back as the whole sentence the wearer said them in, never the bare
/// value: "it was 52 psi, not 25" must keep its correction, and a bare "25" would re-introduce the
/// outdated reading on its own.
enum TimelineDetailCheck {

    /// The fixed line the restored sentences sit under.
    static let heading = "Said word for word:"
    /// About this many characters of a sentence are kept, centred on the value when it is longer.
    static let sentenceLimit = 140
    /// At most this many sentences are restored to one note.
    static let lineLimit = 20

    struct Message: Equatable, Sendable {
        let role: String
        let text: String
        let timestamp: Date

        init(role: String, text: String, timestamp: Date) {
            self.role = role
            self.text = text
            self.timestamp = timestamp
        }

        init(_ message: ConversationMessage) {
            self.init(role: message.role, text: message.content, timestamp: message.timestamp)
        }
    }

    /// One figure or code found in what the wearer said.
    struct Detail: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable { case measurement, code }
        let kind: Kind
        /// As written.
        let value: String
        /// Lowercased, with the space between a number and its unit taken out: what is compared.
        let normalised: String
        let range: Range<String.Index>
    }

    struct Result: Equatable, Sendable {
        /// The summary, with the restored sentences appended when any were lost.
        let text: String
        /// The restored lines, in order, as they appear under `heading`.
        let restoredLines: [String]
        /// How many distinct values the summary had lost, before deduplication and the cap.
        let lostValues: Int
    }

    /// Check `summary` against the wearer's messages in the chunk it was written from.
    static func check(summary: String, messages: [Message], timeZone: TimeZone) -> Result {
        // Two readings of the summary: the joined one finds "52 PSI" as "52psi", and the plain one
        // finds a code followed by a word ("A44 on"), which joining would glue into "a44on".
        let haystacks = [summary.lowercased(), normalisedForSearch(summary)]
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm"

        var seenValues = Set<String>()
        var seenLines = Set<String>()
        var lines: [String] = []
        var lost = 0
        for message in messages where message.role == "user" {
            for detail in details(in: message.text) where !seenValues.contains(detail.normalised) {
                seenValues.insert(detail.normalised)
                guard !haystacks.contains(where: { contains($0, detail.normalised) }) else { continue }
                lost += 1
                let sentence = excerpt(around: detail.range, in: message.text)
                let line = "- \(clock.string(from: message.timestamp)) \"\(sentence)\""
                guard lines.count < lineLimit, seenLines.insert(line).inserted else { continue }
                lines.append(line)
            }
        }
        guard !lines.isEmpty else {
            return Result(text: summary, restoredLines: [], lostValues: lost)
        }
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n" + heading + "\n" + lines.joined(separator: "\n")
        return Result(text: text, restoredLines: lines, lostValues: lost)
    }

    // MARK: - Finding details

    /// Every measurement and code in `text`, in order of appearance. A code that is really a
    /// measurement written without its space ("120V") is counted once, as the measurement.
    static func details(in text: String) -> [Detail] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Detail] = []
        for match in measurementPattern.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            found.append(detail(.measurement, range, in: text))
        }
        for match in codePattern.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let value = String(text[range])
            guard value.filter({ $0 != "-" }).count >= 3,
                  value.range(of: #"^\d+(st|nd|rd|th)$"#, options: [.regularExpression, .caseInsensitive]) == nil,
                  !found.contains(where: { $0.range.overlaps(range) }) else { continue }
            found.append(detail(.code, range, in: text))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func detail(_ kind: Detail.Kind, _ range: Range<String.Index>,
                               in text: String) -> Detail {
        let value = String(text[range])
        return Detail(kind: kind, value: value,
                      normalised: value.lowercased().filter { !$0.isWhitespace }, range: range)
    }

    private static let number = #"-?\d+(?:\.\d+)?"#
    private static let fraction = #"\d+/\d+"#

    /// A number, an optional space, and a unit a technician says out loud. The single letters
    /// (A, V, W) are matched upper case only, so "3 a day" is not a current; a bare "in" counts
    /// only after a fraction, so "3 in the morning" is not a length.
    private static let measurementPattern = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}./])(?:"#
        + "(?:\(fraction)|\(number))\\s?(?:"
        + #"°\s?[CFcf]|(?i:degrees?(?:\s?[cf])?|psig|psi|kpa|mpa|bar|amps?|ma|volts?|vac|vdc|mv|kw|"#
        + #"hz|khz|ohms?|k?Ω|mfd|µf|μf|uf|btu|cfm|gpm|rpm|mm|cm|inch(?:es)?|ft|feet|kg|lbs?|oz|ml)"#
        + #"|°|%|A|V|v|W)"#
        + "|\(fraction)\\s?(?i:in)"
        + #")(?![\p{L}\p{N}])"#)

    /// Letters and digits together, hyphens allowed inside: LX-4410B, E47, R410A.
    private static let codePattern = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}-])(?=[A-Za-z0-9-]*[A-Za-z])(?=[A-Za-z0-9-]*[0-9])"#
        + #"[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*(?![\p{L}\p{N}-])"#)

    // MARK: - Comparing

    /// The summary as values are looked for in it: lowercased, with the space between a number
    /// (or a degree sign) and what follows taken out, so "52 PSI" and "52psi" read alike.
    static func normalisedForSearch(_ summary: String) -> String {
        summary.lowercased().replacingOccurrences(
            of: #"(?<=[0-9°])\s+(?=[\p{L}°%])"#, with: "", options: .regularExpression)
    }

    /// Whether `value` stands on its own in `haystack`: "52psi" is not found inside "152psi", and
    /// "e47" is not found inside "e470".
    static func contains(_ haystack: String, _ value: String) -> Bool {
        let pattern = #"(?<![\p{L}\p{N}.])"# + NSRegularExpression.escapedPattern(for: value)
            + #"(?![\p{L}\p{N}])"#
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - The sentence

    /// The sentence holding `range`, trimmed to about `sentenceLimit` characters around it.
    static func excerpt(around range: Range<String.Index>, in text: String) -> String {
        var start = text.startIndex
        var end = text.endIndex
        // A sentence ends at . ! ? followed by space, or at a line break. "3.2" has no space after
        // its point, so a decimal never splits one.
        let boundaries = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+|\n+"#)
        for match in boundaries.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let cut = Range(match.range, in: text) else { continue }
            if cut.upperBound <= range.lowerBound {
                start = cut.upperBound
            } else if cut.lowerBound >= range.upperBound {
                end = cut.lowerBound
                break
            }
        }
        let sentence = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.count > sentenceLimit else { return sentence }

        // Too long: keep a window around the value, marked where it was cut.
        let characters = Array(text[start..<end])
        let valueStart = text.distance(from: start, to: range.lowerBound)
        let valueLength = text.distance(from: range.lowerBound, to: range.upperBound)
        var from = max(0, valueStart - max(0, sentenceLimit - valueLength) / 2)
        let to = min(characters.count, from + sentenceLimit)
        from = max(0, to - sentenceLimit)
        let window = String(characters[from..<to]).trimmingCharacters(in: .whitespaces)
        return (from > 0 ? "…" : "") + window + (to < characters.count ? "…" : "")
    }
}
