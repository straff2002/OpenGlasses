import Foundation

/// The text a turn's on-device reading actually recognised (Plan NA §2), so the reply check can
/// tell a dose, a date or an amount the wearer's item shows from one the model filled in.
///
/// Two sources: `ReadingAccessibilityTool`'s recognised text (not `define` from a spoken term,
/// which captures nothing) and `look_closely`'s partial transcription on its degraded path. A
/// usable `look_closely` capture is read by the model from the picture and has no on-device text,
/// so it publishes nothing and the reading-number check does not run on that turn.
///
/// Memory only. Built when the tool returns, held for the turn and cleared at its end; it is never
/// logged, written or sent anywhere the recognised text is not already sent. Only the folded text
/// and the numbers in it are kept.
struct ReadingEvidence: Equatable, Sendable {

    enum Source: String, Sendable {
        case readingTool
        case lookClosely
    }

    let source: Source
    /// The recognised text, lowercased and with the usual OCR confusions folded where they touch a
    /// digit (`ReadingQuantityReader.foldOCR`). Used for month names; never logged.
    let foldedText: String
    /// Every number the recognised text contains, by value, read every way the reply's numbers
    /// are read and then some: a reading that is too lenient lets a sentence through, one that is
    /// too strict withholds a dose the wearer's box really shows.
    let values: [Decimal]

    /// Nil when nothing was recognised: no text is no basis for a check.
    init?(text: String, source: Source) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.source = source
        let folded = ReadingQuantityReader.foldOCR(ReplyPhraseMechanics.normalised(trimmed))
        foldedText = folded
        values = ReadingQuantityReader.evidenceValues(in: folded)
    }

    /// Whether `value` occurs in the recognised text.
    func contains(_ value: Decimal) -> Bool { values.contains(value) }

    /// Whether the recognised text names this month (1–12), by its English name, its common
    /// abbreviation or its number.
    func namesMonth(_ month: Int) -> Bool {
        ReadingQuantityReader.text(foldedText, namesMonth: month) || contains(Decimal(month))
    }
}

/// Where a turn's reading evidence waits for the reply that reads from it.
///
/// One slot, the latest reading, published by the reading tools and cleared at each turn's
/// boundary: a Direct turn clears it when it starts and when it finishes, a live session at each
/// turn complete or interruption and when the session ends. A tool reads only what it recognised;
/// the reply check is the only reader. Memory only.
@MainActor
final class ReadingEvidenceBoard {
    static let shared = ReadingEvidenceBoard()

    private(set) var current: ReadingEvidence?

    init() {}

    /// A reading tool recognised `text`. Empty text clears the slot rather than leaving an older
    /// reading in it: the turn's latest reading is the one the reply is about.
    func publish(_ text: String, source: ReadingEvidence.Source) {
        current = ReadingEvidence(text: text, source: source)
    }

    func clear() { current = nil }
}
