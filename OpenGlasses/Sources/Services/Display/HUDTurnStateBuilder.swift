import Foundation

/// Builds the lens's Listening and Thinking cards for a turn the wearer started (Plan LC §4). Pure:
/// the Stop press is reported through the injected `onStop`.
///
/// | Card | Heading | Lines | Buttons |
/// |---|---|---|---|
/// | Listening | "Listening…" | the live partial transcript, newest words kept (body style) | Stop (focused) |
/// | Thinking | "Thinking…" | "You: …", what was heard (meta style, one display line) | Stop (focused) |
///
/// Listening shows the transcript's *tail*: the wearer is checking that the words they are saying
/// now were heard, so the start of a long utterance gives way, not the end. Thinking shows the
/// heard question the way the answer card does (`HUDAnswerCardBuilder.questionLine`), so the lens
/// reads the same from the moment the wearer stops to the answer's first page. Stop ends in
/// `.stop`, so `HUDExit` counts it as each card's way out.
enum HUDTurnStateBuilder {

    /// Stable item ids, so a band press routes back by id.
    enum ItemID {
        static let stop = "lc.turn.stop"
    }

    static var listeningTitle: String {
        String(localized: "Listening…", comment: "Glasses: heading while the app hears the wearer's question.")
    }

    static var thinkingTitle: String {
        String(localized: "Thinking…", comment: "Glasses: heading while the assistant works on the wearer's question.")
    }

    /// The Listening card. `partial` is the recogniser's current transcript (nil or empty before
    /// the first word), cut to its last `maxChars` characters.
    static func listening(partial: String?, maxChars: Int = HUDTextShaper.maxBodyLength,
                          onStop: @escaping () -> Void) -> HUDScreen {
        var lines: [HUDLine] = []
        if let partial {
            let heard = tail(partial, max: maxChars)
            if !heard.isEmpty { lines.append(HUDLine(heard, emphasis: .primary)) }
        }
        return HUDScreen(title: listeningTitle, lines: lines, items: [stopItem(onStop)],
                         focusItemID: ItemID.stop)
    }

    /// The Thinking card. `question` is what was heard; `lineChars` is one display line, so the
    /// question line never wraps (the answer card's rule).
    static func thinking(question: String?, lineChars: Int,
                         onStop: @escaping () -> Void) -> HUDScreen {
        var lines: [HUDLine] = []
        if let line = HUDAnswerCardBuilder.questionLine(for: question, maxChars: lineChars) {
            lines.append(HUDLine(line, emphasis: .meta))
        }
        return HUDScreen(title: thinkingTitle, lines: lines, items: [stopItem(onStop)],
                         focusItemID: ItemID.stop)
    }

    private static func stopItem(_ onStop: @escaping () -> Void) -> HUDItem {
        HUDItem(id: ItemID.stop,
                label: String(localized: "Stop", comment: "Glasses: stop button on the Listening and Thinking cards."),
                style: .secondary, action: onStop)
    }

    /// Whitespace collapsed and cut to its last `max` characters at a word boundary, with a leading
    /// "…" when anything was cut. The mirror of `HUDTextShaper.condense`, which keeps the start.
    static func tail(_ text: String, max: Int) -> String {
        let collapsed = HUDTextShaper.condense(text, max: Int.max)
        guard max > 1, collapsed.count > max else { return collapsed }
        let cut = collapsed.suffix(max - 1)
        // Prefer to start on a word, so the first word shown is whole.
        if let firstSpace = cut.firstIndex(of: " "),
           cut.distance(from: cut.startIndex, to: firstSpace) < (max - 1) / 2 {
            return "…" + cut[cut.index(after: firstSpace)...]
        }
        return "…" + cut
    }
}

/// Plan LC §4: how often the Listening card follows the live transcript. At most one partial per
/// `gap` (the render queue's own text gap, `HUDSendPacer.textGap`, as hermes-glasses does), and the
/// final transcript always. A partial that arrives inside the gap is not dropped for good: the
/// caller waits out the gap and sends the newest one then. Pure.
struct HUDPartialThrottle: Equatable {
    static let gap: TimeInterval = HUDSendPacer.textGap
    /// Less than this left of the gap counts as none.
    static let boundaryTolerance: TimeInterval = 0.001

    enum Decision: Equatable {
        case sendNow
        /// Send the newest partial after this long.
        case wait(TimeInterval)
    }

    /// When the last partial was sent. Nil before the first.
    private(set) var lastSentAt: Date?

    func decision(at now: Date, isFinal: Bool) -> Decision {
        guard !isFinal, let lastSentAt else { return .sendNow }
        let elapsed = now.timeIntervalSince(lastSentAt)
        // A clock that went backwards waits for nothing.
        guard elapsed >= 0 else { return .sendNow }
        // A gap that is over to within a millisecond is over: `Date` arithmetic is not exact, and
        // a partial arriving on the boundary should go now rather than arm a nanosecond timer.
        let remaining = Self.gap - elapsed
        return remaining < Self.boundaryTolerance ? .sendNow : .wait(remaining)
    }

    mutating func sent(at now: Date) { lastSentAt = now }

    mutating func reset() { lastSentAt = nil }
}
